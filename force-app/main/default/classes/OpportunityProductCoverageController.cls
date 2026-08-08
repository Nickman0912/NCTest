/**
 * @description Apex controller for the Opportunity Product Coverage LWC.
 *              Given an Opportunity, reads its line items (products), then walks
 *              DOWN the account hierarchy (Relationship__c + Account.ParentId for
 *              schools) to find which descendant accounts already own those products
 *              via Asset records.
 *
 *              Relationship__c convention: Primary_Account__c = CHILD,
 *              Secondary_Account__c = PARENT. Schools use standard Account.ParentId.
 */
public with sharing class OpportunityProductCoverageController {

    // Max depth to traverse to avoid runaway queries on deep hierarchies.
    private static final Integer MAX_DEPTH = 6;

    public class CoverageResult {
        @AuraEnabled public String opportunityName;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountRecordType;
        @AuraEnabled public String accountId;
        @AuraEnabled public List<ProductCoverage> products;
        @AuraEnabled public List<HierarchyAccount> hierarchyAccounts;
        @AuraEnabled public Integer totalAccounts;
        @AuraEnabled public Integer totalAccountsWithOwnership;
        @AuraEnabled public Integer totalMatchingAssets;
    }

    public class ProductCoverage {
        @AuraEnabled public String productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String family;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal totalPrice;
        @AuraEnabled public Integer ownerCount;
        @AuraEnabled public Integer assetCount;
    }

    public class HierarchyAccount {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String recordType;
        @AuraEnabled public Integer depth;
        @AuraEnabled public String parentName;
        @AuraEnabled public String parentId;
        @AuraEnabled public String accountUrl;
        @AuraEnabled public List<OwnedAsset> ownedAssets;
        @AuraEnabled public Boolean isSelf;
    }

    public class OwnedAsset {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String status;
        @AuraEnabled public Date installDate;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public String assetUrl;
    }

    /**
     * @description Main entry point — computes product coverage across the
     *              opportunity's account hierarchy.
     * @param opportunityId The Opportunity whose line items to analyze.
     * @return CoverageResult with products, hierarchy accounts, and summary stats.
     */
    @AuraEnabled(cacheable=true)
    public static CoverageResult getProductCoverage(Id opportunityId) {
        Opportunity opp = [
            SELECT Id, Name, AccountId, Account.Name, Account.RecordType.DeveloperName
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];

        CoverageResult result = new CoverageResult();
        result.opportunityName = opp.Name;
        result.accountId = opp.AccountId;
        result.accountName = opp.Account.Name;
        result.accountRecordType = opp.Account.RecordType.DeveloperName;
        result.products = new List<ProductCoverage>();
        result.hierarchyAccounts = new List<HierarchyAccount>();
        result.totalAccounts = 0;
        result.totalAccountsWithOwnership = 0;
        result.totalMatchingAssets = 0;

        // ── 1. Gather opportunity products ──────────────────────────────
        List<OpportunityLineItem> lineItems = [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Family,
                   Quantity, UnitPrice, TotalPrice
            FROM OpportunityLineItem
            WHERE OpportunityId = :opportunityId
            ORDER BY Product2.Name
        ];

        if (lineItems.isEmpty()) {
            return result;
        }

        Set<Id> productIds = new Set<Id>();
        for (OpportunityLineItem oli : lineItems) {
            ProductCoverage pc = new ProductCoverage();
            pc.productId = oli.Product2Id;
            pc.productName = oli.Product2.Name;
            pc.productCode = oli.Product2.ProductCode;
            pc.family = oli.Product2.Family;
            pc.quantity = oli.Quantity;
            pc.unitPrice = oli.UnitPrice;
            pc.totalPrice = oli.TotalPrice;
            pc.ownerCount = 0;
            pc.assetCount = 0;
            result.products.add(pc);
            productIds.add(oli.Product2Id);
        }

        // ── 2. Walk DOWN the hierarchy from the opportunity's account ────
        // BFS with visited set + depth cap. Includes the context account itself
        // (depth 0, isSelf=true) so we can see if it already owns the products.
        Map<Id, HierarchyAccount> accountMap = new Map<Id, HierarchyAccount>();
        List<Account> contextAccount = [
            SELECT Id, Name, RecordType.DeveloperName
            FROM Account
            WHERE Id = :opp.AccountId
            LIMIT 1
        ];

        HierarchyAccount self = new HierarchyAccount();
        self.id = contextAccount[0].Id;
        self.name = contextAccount[0].Name;
        self.recordType = contextAccount[0].RecordType.DeveloperName;
        self.depth = 0;
        self.parentName = null;
        self.parentId = null;
        self.accountUrl = '/lightning/r/Account/' + self.id + '/view';
        self.ownedAssets = new List<OwnedAsset>();
        self.isSelf = true;
        accountMap.put(self.id, self);

        // BFS queue of { accountId, depth }
        List<QueueItem> queue = new List<QueueItem>();
        queue.add(new QueueItem(opp.AccountId, 0));
        Set<Id> visited = new Set<Id>{ opp.AccountId };

        while (!queue.isEmpty()) {
            QueueItem current = queue.remove(0);
            if (current.depth >= MAX_DEPTH) {
                continue;
            }

            // Children via Relationship__c (Secondary = parent → Primary = child)
            for (Relationship__c rel : [
                SELECT Id, Primary_Account__c, Primary_Account__r.Name,
                       Primary_Account__r.RecordType.DeveloperName
                FROM Relationship__c
                WHERE Secondary_Account__c = :current.accountId
                ORDER BY Primary_Account__r.Name
            ]) {
                if (visited.add(rel.Primary_Account__c)) {
                    HierarchyAccount child = new HierarchyAccount();
                    child.id = rel.Primary_Account__c;
                    child.name = rel.Primary_Account__r.Name;
                    child.recordType = rel.Primary_Account__r.RecordType.DeveloperName;
                    child.depth = current.depth + 1;
                    child.parentName = accountMap.get(current.accountId)?.name;
                    child.parentId = current.accountId;
                    child.accountUrl = '/lightning/r/Account/' + child.id + '/view';
                    child.ownedAssets = new List<OwnedAsset>();
                    child.isSelf = false;
                    accountMap.put(child.id, child);
                    queue.add(new QueueItem(child.id, child.depth));
                }
            }

            // Children via Account.ParentId (Schools under a District)
            for (Account school : [
                SELECT Id, Name, RecordType.DeveloperName
                FROM Account
                WHERE ParentId = :current.accountId
                ORDER BY Name
            ]) {
                if (visited.add(school.Id)) {
                    HierarchyAccount child = new HierarchyAccount();
                    child.id = school.Id;
                    child.name = school.Name;
                    child.recordType = school.RecordType.DeveloperName;
                    child.depth = current.depth + 1;
                    child.parentName = accountMap.get(current.accountId)?.name;
                    child.parentId = current.accountId;
                    child.accountUrl = '/lightning/r/Account/' + child.id + '/view';
                    child.ownedAssets = new List<OwnedAsset>();
                    child.isSelf = false;
                    accountMap.put(child.id, child);
                    queue.add(new QueueItem(child.id, child.depth));
                }
            }
        }

        // ── 3. Query Assets for all accounts in the hierarchy ───────────
        Set<Id> allAccountIds = accountMap.keySet();
        List<Asset> assets = [
            SELECT Id, Name, AccountId, Product2Id, Product2.Name, Status, InstallDate, Quantity
            FROM Asset
            WHERE AccountId IN :allAccountIds
              AND Product2Id IN :productIds
            ORDER BY Product2.Name, Name
        ];

        // Map productId → ProductCoverage for quick lookup
        Map<Id, ProductCoverage> productMap = new Map<Id, ProductCoverage>();
        for (ProductCoverage pc : result.products) {
            productMap.put(pc.productId, pc);
        }

        for (Asset a : assets) {
            OwnedAsset oa = new OwnedAsset();
            oa.id = a.Id;
            oa.name = a.Name;
            oa.productId = a.Product2Id;
            oa.productName = a.Product2.Name;
            oa.status = a.Status;
            oa.installDate = a.InstallDate;
            oa.quantity = a.Quantity;
            oa.assetUrl = '/lightning/r/Asset/' + a.Id + '/view';

            HierarchyAccount ha = accountMap.get(a.AccountId);
            if (ha != null) {
                ha.ownedAssets.add(oa);
                result.totalMatchingAssets++;
            }

            ProductCoverage pc = productMap.get(a.Product2Id);
            if (pc != null) {
                pc.assetCount++;
            }
        }

        // ── 4. Compute per-product owner counts + account ownership flags ─
        for (HierarchyAccount ha : accountMap.values()) {
            if (!ha.ownedAssets.isEmpty()) {
                result.totalAccountsWithOwnership++;
                Set<Id> ownedProductIds = new Set<Id>();
                for (OwnedAsset oa : ha.ownedAssets) {
                    ownedProductIds.add(oa.productId);
                }
                for (Id pid : ownedProductIds) {
                    ProductCoverage pc = productMap.get(pid);
                    if (pc != null) {
                        pc.ownerCount++;
                    }
                }
            }
        }

        // ── 5. Sort hierarchy accounts by depth then name ───────────────
        List<HierarchyAccount> sorted = new List<HierarchyAccount>(accountMap.values());
        sorted.sort(new HierarchyAccountComparator());
        result.hierarchyAccounts = sorted;
        result.totalAccounts = sorted.size();

        return result;
    }

    // ─── Helper classes ─────────────────────────────────────────────────
    private class QueueItem {
        public Id accountId;
        public Integer depth;
        public QueueItem(Id accountId, Integer depth) {
            this.accountId = accountId;
            this.depth = depth;
        }
    }

    private class HierarchyAccountComparator implements Comparator<HierarchyAccount> {
        public Integer compare(HierarchyAccount a, HierarchyAccount b) {
            if (a.depth != b.depth) {
                return a.depth - b.depth;
            }
            return a.name.compareTo(b.name);
        }
    }
}