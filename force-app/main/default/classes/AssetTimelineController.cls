/**
 * @description Apex controller for the Asset Renewal Timeline LWC.
 *              Queries Assets for a given Account whose UsageEndDate falls
 *              within the next 18 months, and exposes an imperative method
 *              to create a linked Renewal Opportunity for a given Asset.
 */
public with sharing class AssetTimelineController {

    /**
     * @description Number of months in the rolling renewal window.
     */
    private static final Integer WINDOW_MONTHS = 18;

    /**
     * @description Lightweight wrapper returned to the LWC for a single Asset.
     */
    public class AssetTimelineItem {
        @AuraEnabled public String assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public Date expirationDate;
        @AuraEnabled public String productFamily;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String status;
        @AuraEnabled public String renewalOpportunityId;
        @AuraEnabled public String renewalOpportunityName;
        @AuraEnabled public String purchasedById;
        @AuraEnabled public String purchasedByName;
        @AuraEnabled public Boolean isSelfPurchased;
    }

    /**
     * @description Main entry point — returns all Assets for the given Account
     *              whose UsageEndDate falls within the next 18 months.
     * @param accountId The Account whose assets to load.
     * @return List<AssetTimelineItem> sorted by expiration date ascending.
     */
    @AuraEnabled(cacheable=true)
    public static List<AssetTimelineItem> getTimelineData(Id accountId) {
        // Validate the incoming Id is an Account
        if (accountId == null || accountId.getSObjectType() != Account.SObjectType) {
            throw new AuraHandledException('A valid Account Id is required.');
        }

        // Compute the 18-month window bounds
        Date today = Date.today();
        Date windowEnd = today.addMonths(WINDOW_MONTHS);

        // Query Assets for this Account expiring within the window.
        // Uses standard UsageEndDate as the expiration date.
        List<Asset> assets = [
            SELECT Id, Name, UsageEndDate, Status, Price, AccountId,
                   Product2Id, Product2.Name, Product2.Family,
                   Renewal_Opportunity__c, Renewal_Opportunity__r.Name,
                   Purchased_By__c, Purchased_By__r.Name
            FROM Asset
            WHERE AccountId = :accountId
              AND UsageEndDate != null
              AND UsageEndDate >= :today
              AND UsageEndDate <= :windowEnd
            ORDER BY UsageEndDate ASC, Name ASC
        ];

        // Map each Asset to the lightweight wrapper
        List<AssetTimelineItem> items = new List<AssetTimelineItem>();
        for (Asset a : assets) {
            items.add(mapAsset(a));
        }
        return items;
    }

    /**
     * @description Creates a Renewal Opportunity for a single Asset by
     *              delegating to the bulk grouping method.
     * @param accountId The Account the Opportunity should be associated with.
     * @param assetId   The Asset being renewed.
     * @return Id of the newly created Opportunity.
     */
    @AuraEnabled
    public static Id createRenewalOpportunity(Id accountId, Id assetId) {
        return createRenewalOpportunities(accountId, new List<Id>{ assetId });
    }

    /**
     * @description Creates ONE Renewal Opportunity that groups multiple Assets,
     *              then links every selected Asset back to the new Opportunity.
     *              The Opportunity name is based on the first (earliest)
     *              expiring Asset, the Amount is the sum of all Asset prices,
     *              and the CloseDate is the earliest UsageEndDate.
     * @param accountId The Account the Opportunity should be associated with.
     * @param assetIds  The Assets to group into the renewal.
     * @return Id of the newly created (grouped) Opportunity.
     */
    @AuraEnabled
    public static Id createRenewalOpportunities(Id accountId, List<Id> assetIds) {
        // ---- Validate inputs ----
        if (accountId == null || assetIds == null || assetIds.isEmpty()) {
            throw new AuraHandledException('Account Id and at least one Asset Id are required.');
        }

        // Strip any null entries defensively (Aura can pass nulls in boundary cases)
        List<Id> safeIds = new List<Id>();
        for (Id id : assetIds) {
            if (id != null) {
                safeIds.add(id);
            }
        }
        if (safeIds.isEmpty()) {
            throw new AuraHandledException('At least one valid Asset Id is required.');
        }

        // ---- Load the Assets (includes Product2 and the Account name) ----
        List<Asset> assets = [
            SELECT Id, Name, UsageEndDate, Price, Product2Id, Renewal_Opportunity__c,
                   Purchased_By__c, Purchased_By__r.Name
            FROM Asset
            WHERE Id IN :safeIds
            ORDER BY UsageEndDate ASC NULLS LAST, Name ASC
        ];

        if (assets.isEmpty()) {
            throw new AuraHandledException('No valid Assets were found for the provided Ids.');
        }

        // ---- Duplicate guard: reject the whole batch if ANY Asset already
        //      has a renewal, so we never create a partial/duplicate grouping ----
        for (Asset a : assets) {
            if (a.Renewal_Opportunity__c != null) {
                throw new AuraHandledException(
                    'A Renewal Opportunity already exists for ' + a.Name + '.'
                );
            }
        }

        // ---- Determine the target Account for the Opportunity ----
        // If all selected Assets share the same effective purchaser, the
        // Opportunity is created for that purchaser. If purchasers differ,
        // the Opportunity is created for the current (context) Account.
        Set<Id> purchaserIds = new Set<Id>();
        for (Asset a : assets) {
            Id purchaserId = a.Purchased_By__c != null ? a.Purchased_By__c : accountId;
            purchaserIds.add(purchaserId);
        }

        Id targetAccountId = accountId;
        if (purchaserIds.size() == 1) {
            targetAccountId = new List<Id>(purchaserIds)[0];
        }

        String targetAccountName = '';
        Account targetAcct = [SELECT Name FROM Account WHERE Id = :targetAccountId LIMIT 1];
        if (targetAcct != null && targetAcct.Name != null) {
            targetAccountName = targetAcct.Name;
        }

        // ---- Aggregates: earliest expiration & summed amount ----
        Decimal totalAmount = 0;
        Date earliestEnd = null;
        for (Asset a : assets) {
            if (a.Price != null) {
                totalAmount += a.Price;
            }
            if (a.UsageEndDate != null &&
                (earliestEnd == null || a.UsageEndDate < earliestEnd)) {
                earliestEnd = a.UsageEndDate;
            }
        }

        // ---- Name pattern: "<Account Name> - Renewal - <MMM yyyy>" ----
        String monthYear = '';
        if (earliestEnd != null) {
            monthYear = formatMonthYear(earliestEnd);
        }
        String oppName = targetAccountName + ' - Renewal';
        if (String.isNotBlank(monthYear)) {
            oppName += ' - ' + monthYear;
        }

        // ---- Resolve the price book for OpportunityLineItems ----
        Id pricebookId = getStandardPricebookId();

        // Build the grouped Opportunity (amount set defensively; often
        // overridden by the system total from line items)
        Opportunity renewal = new Opportunity(
            Name = oppName,
            AccountId = targetAccountId,
            StageName = 'Prospecting',
            CloseDate = earliestEnd != null ? earliestEnd : Date.today().addMonths(1),
            Amount = totalAmount,
            Pricebook2Id = pricebookId
        );

        // FLS-safe insert (strips fields the user cannot create)
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<Opportunity>{ renewal }
        );
        if (decision.getRecords().isEmpty()) {
            throw new AuraHandledException('You do not have permission to create Opportunities.');
        }
        insert decision.getRecords();

        // ---- Link EVERY selected Asset to the new Opportunity ----
        List<Asset> assetsToUpdate = new List<Asset>();
        for (Asset a : assets) {
            assetsToUpdate.add(new Asset(
                Id = a.Id,
                Renewal_Opportunity__c = decision.getRecords()[0].Id
            ));
        }

        SObjectAccessDecision updateDecision = Security.stripInaccessible(
            AccessType.UPDATABLE,
            assetsToUpdate
        );
        if (!updateDecision.getRecords().isEmpty()) {
            update updateDecision.getRecords();
        }

        // ---- Associate each renewed Product with the Opportunity ----
        // Requires an active price book + PricebookEntry per product. We
        // auto-create missing PricebookEntries so Product-less Groups still
        // create the Opportunity without errors.
        addOpportunityLineItems(decision.getRecords()[0].Id, pricebookId, assets);

        return decision.getRecords()[0].Id;
    }

    /**
     * @description Resolves the Standard (or a fallback active) Price Book Id.
     *              Uses Test.getStandardPricebookId() in tests so no real DML
     *              is needed for the standard record.
     */
    private static Id getStandardPricebookId() {
        if (Test.isRunningTest()) {
            return Test.getStandardPricebookId();
        }
        List<Pricebook2> pbs = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true
            LIMIT 1
        ];
        if (!pbs.isEmpty()) {
            return pbs[0].Id;
        }
        // Fallback: any active price book
        List<Pricebook2> active = [
            SELECT Id
            FROM Pricebook2
            WHERE IsActive = true
            LIMIT 1
        ];
        return active.isEmpty() ? null : active[0].Id;
    }

    /**
     * @description Creates OpportunityLineItems for every Asset that has a
     *              Product2Id. Missing PricebookEntries are created first so
     *              the line items can be inserted.
     */
    private static void addOpportunityLineItems(Id oppId, Id pricebookId, List<Asset> assets) {
        if (pricebookId == null) {
            return;
        }

        // Collect the products referenced by the selected Assets
        Set<Id> productIds = new Set<Id>();
        Map<Id, Asset> assetByProduct = new Map<Id, Asset>();
        for (Asset a : assets) {
            if (a.Product2Id != null && !productIds.contains(a.Product2Id)) {
                productIds.add(a.Product2Id);
                assetByProduct.put(a.Product2Id, a);
            }
        }
        if (productIds.isEmpty()) {
            return;
        }

        // Find existing price book entries for these products
        Map<Id, PricebookEntry> entriesByProduct = new Map<Id, PricebookEntry>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id, UnitPrice, Pricebook2Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
              AND Product2Id IN :productIds
        ]) {
            entriesByProduct.put(pbe.Product2Id, pbe);
        }

        // Auto-create missing price book entries
        List<PricebookEntry> entriesToInsert = new List<PricebookEntry>();
        for (Id productId : productIds) {
            if (!entriesByProduct.containsKey(productId)) {
                Asset a = assetByProduct.get(productId);
                entriesToInsert.add(new PricebookEntry(
                    Pricebook2Id = pricebookId,
                    Product2Id = productId,
                    IsActive = true,
                    UnitPrice = a.Price != null ? a.Price : 0
                ));
            }
        }
        if (!entriesToInsert.isEmpty()) {
            SObjectAccessDecision entryDecision = Security.stripInaccessible(
                AccessType.CREATABLE,
                entriesToInsert
            );
            if (!entryDecision.getRecords().isEmpty()) {
                insert entryDecision.getRecords();
                for (SObject pbe : entryDecision.getRecords()) {
                    entriesByProduct.put((Id) pbe.get('Product2Id'), (PricebookEntry) pbe);
                }
            }
        }

        // Build the line items (one per Asset that has a Product)
        List<OpportunityLineItem> lineItems = new List<OpportunityLineItem>();
        for (Asset a : assets) {
            if (a.Product2Id != null && entriesByProduct.containsKey(a.Product2Id)) {
                lineItems.add(new OpportunityLineItem(
                    OpportunityId = oppId,
                    PricebookEntryId = entriesByProduct.get(a.Product2Id).Id,
                    Quantity = 1,
                    UnitPrice = a.Price != null ? a.Price : 0
                ));
            }
        }
        if (!lineItems.isEmpty()) {
            SObjectAccessDecision lineItemDecision = Security.stripInaccessible(
                AccessType.CREATABLE,
                lineItems
            );
            if (!lineItemDecision.getRecords().isEmpty()) {
                insert lineItemDecision.getRecords();
            }
        }
    }

    /**
     * @description Formats a Date as "MMM yyyy" (e.g. "Nov 2026").
     */
    private static String formatMonthYear(Date d) {
        if (d == null) {
            return '';
        }
        // Months are 1-based in Apex
        List<String> months = new List<String>{
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        };
        return months[d.month() - 1] + ' ' + d.year();
    }

    /**
     * @description Maps an Asset SObject to the lightweight AssetTimelineItem wrapper.
     */
    private static AssetTimelineItem mapAsset(Asset a) {
        AssetTimelineItem item = new AssetTimelineItem();
        item.assetId = a.Id;
        item.assetName = a.Name;
        item.expirationDate = a.UsageEndDate;
        item.productFamily = a.Product2Id != null ? a.Product2.Family : '';
        item.productName = a.Product2Id != null ? a.Product2.Name : '';
        item.amount = a.Price;
        item.status = a.Status != null ? a.Status : '';
        item.renewalOpportunityId = a.Renewal_Opportunity__c;
        item.renewalOpportunityName = a.Renewal_Opportunity__r != null
            ? a.Renewal_Opportunity__r.Name : '';
        item.purchasedById = a.Purchased_By__c;
        item.purchasedByName = a.Purchased_By__r != null ? a.Purchased_By__r.Name : '';
        item.isSelfPurchased = a.Purchased_By__c == null || a.Purchased_By__c == a.AccountId;
        return item;
    }
}