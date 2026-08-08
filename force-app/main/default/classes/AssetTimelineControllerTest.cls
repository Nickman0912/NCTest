/**
 * @description Unit tests for AssetTimelineController.
 */
@isTest
private class AssetTimelineControllerTest {

    @IsTest
    static void getTimelineData_returnsAssetsWithinWindow() {
        // Arrange — account, product, asset with a near future expiration
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Product2 prod = new Product2(
            Name = 'Test Product',
            Family = 'Hardware',
            IsActive = true
        );
        insert prod;

        // < 3 months out -> in-window
        Asset inWindow = new Asset(
            Name = 'Expiring Soon',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Status = 'Installed',
            UsageEndDate = Date.today().addMonths(2),
            Price = 1000
        );
        // > 18 months out -> out-of-window
        Asset outOfWindow = new Asset(
            Name = 'Far Future',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Status = 'Installed',
            UsageEndDate = Date.today().addMonths(24),
            Price = 500
        );
        insert new List<Asset>{ inWindow, outOfWindow };

        Test.startTest();
        List<AssetTimelineController.AssetTimelineItem> items =
            AssetTimelineController.getTimelineData(acc.Id);
        Test.stopTest();

        Assert.areEqual(1, items.size(), 'Only the in-window asset should be returned.');
        Assert.areEqual(inWindow.Id, items[0].assetId);
        Assert.areEqual('Hardware', items[0].productFamily);
        Assert.areEqual(1000, items[0].amount);
        Assert.isNull(items[0].renewalOpportunityId, 'Expected no Renewal Opportunity linked.');
    }

    @IsTest
    static void getTimelineData_rejectsNonAccountId() {
        Account acc = new Account(Name = 'Helper Account');
        insert acc;

        Product2 prod = new Product2(Name = 'P', IsActive = true);
        insert prod;
        Asset a = new Asset(
            Name = 'A',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            UsageEndDate = Date.today().addMonths(5)
        );
        insert a;

        // Asset Id does not start with '001' (Account prefix)
        try {
            AssetTimelineController.getTimelineData(a.Id);
            Assert.fail('Expected an exception for a non-Account Id.');
        } catch (Exception e) {
            // In a non-debug test context the AuraHandledException message is
            // surfaced as a generic "Script-thrown exception", so we only
            // assert that the controller correctly rejected the Id.
        }
    }

    @IsTest
    static void createRenewalOpportunity_linksOppToAsset() {
        // Arrange
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Product2 prod = new Product2(Name = 'Product X', IsActive = true);
        insert prod;

        Asset asset = new Asset(
            Name = 'Server A',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Status = 'Installed',
            UsageEndDate = Date.today().addMonths(4),
            Price = 2500
        );
        insert asset;

        // Act
        Test.startTest();
        Id oppId = AssetTimelineController.createRenewalOpportunity(acc.Id, asset.Id);
        Test.stopTest();

        // Assert — opportunity created & linked
        Opportunity opp = [SELECT Id, Name, StageName, CloseDate, Amount, AccountId
                           FROM Opportunity WHERE Id = :oppId];
        Assert.areEqual('Test Account - Renewal - ' + monthYear(asset.UsageEndDate), opp.Name);
        Assert.areEqual('Prospecting', opp.StageName);
        Assert.areEqual(asset.UsageEndDate, opp.CloseDate);
        Assert.areEqual(2500, opp.Amount);
        Assert.areEqual(acc.Id, opp.AccountId);

        Asset updated = [SELECT Id, Renewal_Opportunity__c FROM Asset WHERE Id = :asset.Id];
        Assert.areEqual(oppId, updated.Renewal_Opportunity__c);

        // Assert — the Asset's Product is associated with the Opportunity
        List<OpportunityLineItem> olis = [
            SELECT Id, OpportunityId, PricebookEntryId, PricebookEntry.Product2Id,
                   Quantity, UnitPrice
            FROM OpportunityLineItem
            WHERE OpportunityId = :oppId
        ];
        Assert.areEqual(1, olis.size(), 'One line item should be created.');
        Assert.areEqual(prod.Id, olis[0].PricebookEntry.Product2Id);
        Assert.areEqual(1, olis[0].Quantity);
        Assert.areEqual(2500, olis[0].UnitPrice);
    }

    @IsTest
    static void createRenewalOpportunity_preventsDuplicate() {
        // Arrange
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Asset asset = new Asset(
            Name = 'Server B',
            AccountId = acc.Id,
            UsageEndDate = Date.today().addMonths(6)
        );
        insert asset;

        // First creation succeeds
        AssetTimelineController.createRenewalOpportunity(acc.Id, asset.Id);

        // Second creation should fail (duplicate guard)
        try {
            AssetTimelineController.createRenewalOpportunity(acc.Id, asset.Id);
            Assert.fail('Expected duplicate renewal guard to trigger.');
        } catch (Exception e) {
            // In a non-debug test context the AuraHandledException message is
            // surfaced as a generic "Script-thrown exception", so we only
            // assert that the guard correctly blocked the duplicate.
        }
    }

    @IsTest
    static void getTimelineData_returnsPurchaserInfo() {
        // Arrange — context account + external purchaser account
        Account acc = new Account(Name = 'Context School');
        insert acc;
        Account purchaser = new Account(Name = 'JPA District');
        insert purchaser;

        Product2 prod = new Product2(Name = 'Test Product', IsActive = true);
        insert prod;

        // Self-purchased (Purchased_By__c null)
        Asset self = new Asset(
            Name = 'Self Purchased',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            UsageEndDate = Date.today().addMonths(2),
            Price = 100
        );
        // Externally purchased
        Asset external = new Asset(
            Name = 'External Purchased',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Purchased_By__c = purchaser.Id,
            UsageEndDate = Date.today().addMonths(4),
            Price = 200
        );
        insert new List<Asset>{ self, external };

        Test.startTest();
        List<AssetTimelineController.AssetTimelineItem> items =
            AssetTimelineController.getTimelineData(acc.Id);
        Test.stopTest();

        Assert.areEqual(2, items.size());

        AssetTimelineController.AssetTimelineItem selfItem = null;
        AssetTimelineController.AssetTimelineItem extItem = null;
        for (AssetTimelineController.AssetTimelineItem item : items) {
            if (item.assetId == self.Id) selfItem = item;
            if (item.assetId == external.Id) extItem = item;
        }

        Assert.areNotEqual(null, selfItem, 'Self-purchased asset should be returned.');
        Assert.areNotEqual(null, extItem, 'Externally-purchased asset should be returned.');

        Assert.isTrue(selfItem.isSelfPurchased);
        Assert.isNull(selfItem.purchasedById);
        Assert.areEqual('', selfItem.purchasedByName);

        Assert.isFalse(extItem.isSelfPurchased);
        Assert.areEqual(purchaser.Id, extItem.purchasedById);
        Assert.areEqual('JPA District', extItem.purchasedByName);
    }

    @IsTest
    static void createRenewalOpportunity_externalPurchaser_createsOppForPurchaser() {
        // Arrange — context account + external purchaser
        Account acc = new Account(Name = 'Context School');
        insert acc;
        Account purchaser = new Account(Name = 'JPA District');
        insert purchaser;

        Product2 prod = new Product2(Name = 'Product X', IsActive = true);
        insert prod;

        Asset asset = new Asset(
            Name = 'Server A',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Purchased_By__c = purchaser.Id,
            Status = 'Installed',
            UsageEndDate = Date.today().addMonths(4),
            Price = 2500
        );
        insert asset;

        // Act
        Test.startTest();
        Id oppId = AssetTimelineController.createRenewalOpportunity(acc.Id, asset.Id);
        Test.stopTest();

        // Assert — Opportunity created for the PURCHASER, not the context account
        Opportunity opp = [SELECT Id, Name, StageName, CloseDate, Amount, AccountId
                           FROM Opportunity WHERE Id = :oppId];
        Assert.areEqual('JPA District - Renewal - ' + monthYear(asset.UsageEndDate), opp.Name);
        Assert.areEqual('Prospecting', opp.StageName);
        Assert.areEqual(asset.UsageEndDate, opp.CloseDate);
        Assert.areEqual(2500, opp.Amount);
        Assert.areEqual(purchaser.Id, opp.AccountId, 'Opportunity should be owned by the purchaser.');

        Asset updated = [SELECT Id, Renewal_Opportunity__c FROM Asset WHERE Id = :asset.Id];
        Assert.areEqual(oppId, updated.Renewal_Opportunity__c);

        // Assert — the Asset's Product is associated with the Opportunity
        List<OpportunityLineItem> olis = [
            SELECT Id, OpportunityId, PricebookEntryId, PricebookEntry.Product2Id,
                   Quantity, UnitPrice
            FROM OpportunityLineItem
            WHERE OpportunityId = :oppId
        ];
        Assert.areEqual(1, olis.size(), 'One line item should be created.');
        Assert.areEqual(prod.Id, olis[0].PricebookEntry.Product2Id);
        Assert.areEqual(1, olis[0].Quantity);
        Assert.areEqual(2500, olis[0].UnitPrice);
    }

    @IsTest
    static void createRenewalOpportunities_mixedPurchasers_createsOppForContextAccount() {
        // Arrange — context account + two external purchasers
        Account acc = new Account(Name = 'Context School');
        insert acc;
        Account purchaserA = new Account(Name = 'JPA Alpha');
        insert purchaserA;
        Account purchaserB = new Account(Name = 'JPA Beta');
        insert purchaserB;

        Product2 prod = new Product2(Name = 'Product G', IsActive = true);
        insert prod;

        Asset assetA = new Asset(
            Name = 'Server C',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Purchased_By__c = purchaserA.Id,
            UsageEndDate = Date.today().addMonths(3),
            Price = 1000
        );
        Asset assetB = new Asset(
            Name = 'Server D',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Purchased_By__c = purchaserB.Id,
            UsageEndDate = Date.today().addMonths(9),
            Price = 2000
        );
        insert new List<Asset>{ assetA, assetB };

        // Act — group both into a single renewal (different purchasers)
        List<Id> assetIds = new List<Id>{ assetA.Id, assetB.Id };
        Test.startTest();
        Id oppId = AssetTimelineController.createRenewalOpportunities(acc.Id, assetIds);
        Test.stopTest();

        // Assert — exactly ONE grouped Opportunity on the CONTEXT account
        List<Opportunity> opps = [
            SELECT Id, Name, CloseDate, Amount, AccountId
            FROM Opportunity
            WHERE AccountId = :acc.Id
        ];
        Assert.areEqual(1, opps.size(), 'Exactly one grouped Opportunity should be created.');
        Opportunity grouped = opps[0];
        Assert.areEqual('Context School - Renewal - ' + monthYear(assetA.UsageEndDate), grouped.Name);
        Assert.areEqual(
            assetA.UsageEndDate,
            grouped.CloseDate,
            'CloseDate should be the earliest expiry.'
        );
        Assert.areEqual(3000, grouped.Amount, 'Amount should be the sum of Asset prices.');
        Assert.areEqual(acc.Id, grouped.AccountId, 'Mixed purchasers should create Opp for context account.');

        // Assert — BOTH Assets linked to the same grouped Opportunity
        List<Asset> updated = [
            SELECT Id, Renewal_Opportunity__c
            FROM Asset
            WHERE Id IN :assetIds
        ];
        for (Asset a : updated) {
            Assert.areEqual(
                oppId,
                a.Renewal_Opportunity__c,
                'Every selected Asset must be linked to the grouped Opportunity.'
            );
        }

        // Assert — every renewed Product is on the Opportunity as a line item
        List<OpportunityLineItem> olis = [
            SELECT Id, Quantity, UnitPrice
            FROM OpportunityLineItem
            WHERE OpportunityId = :oppId
        ];
        Assert.areEqual(2, olis.size(), 'One line item per renewed Asset should be created.');
        Assert.areEqual(3000, olis[0].UnitPrice + olis[1].UnitPrice);
    }

    @IsTest
    static void createRenewalOpportunities_sameExternalPurchaser_createsOppForPurchaser() {
        // Arrange — context account + one external purchaser
        Account acc = new Account(Name = 'Context School');
        insert acc;
        Account purchaser = new Account(Name = 'JPA District');
        insert purchaser;

        Product2 prod = new Product2(Name = 'Product G', IsActive = true);
        insert prod;

        Asset assetA = new Asset(
            Name = 'Server C',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Purchased_By__c = purchaser.Id,
            UsageEndDate = Date.today().addMonths(3),
            Price = 1000
        );
        Asset assetB = new Asset(
            Name = 'Server D',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            Purchased_By__c = purchaser.Id,
            UsageEndDate = Date.today().addMonths(9),
            Price = 2000
        );
        insert new List<Asset>{ assetA, assetB };

        // Act — group both into a single renewal (same purchaser)
        List<Id> assetIds = new List<Id>{ assetA.Id, assetB.Id };
        Test.startTest();
        Id oppId = AssetTimelineController.createRenewalOpportunities(acc.Id, assetIds);
        Test.stopTest();

        // Assert — exactly ONE grouped Opportunity on the PURCHASER account
        List<Opportunity> opps = [
            SELECT Id, Name, CloseDate, Amount, AccountId
            FROM Opportunity
            WHERE AccountId = :purchaser.Id
        ];
        Assert.areEqual(1, opps.size(), 'Exactly one grouped Opportunity should be created.');
        Opportunity grouped = opps[0];
        Assert.areEqual('JPA District - Renewal - ' + monthYear(assetA.UsageEndDate), grouped.Name);
        Assert.areEqual(
            assetA.UsageEndDate,
            grouped.CloseDate,
            'CloseDate should be the earliest expiry.'
        );
        Assert.areEqual(3000, grouped.Amount, 'Amount should be the sum of Asset prices.');
        Assert.areEqual(purchaser.Id, grouped.AccountId, 'Same purchaser should create Opp for purchaser.');

        // Assert — BOTH Assets linked to the same grouped Opportunity
        List<Asset> updated = [
            SELECT Id, Renewal_Opportunity__c
            FROM Asset
            WHERE Id IN :assetIds
        ];
        for (Asset a : updated) {
            Assert.areEqual(
                oppId,
                a.Renewal_Opportunity__c,
                'Every selected Asset must be linked to the grouped Opportunity.'
            );
        }
    }

    @IsTest
    static void createRenewalOpportunities_groupsMultipleAssets() {
        // Arrange — account + two assets expiring at different dates
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Product2 prod = new Product2(Name = 'Product G', IsActive = true);
        insert prod;

        Asset earlier = new Asset(
            Name = 'Server C',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            UsageEndDate = Date.today().addMonths(3),
            Price = 1000
        );
        Asset later = new Asset(
            Name = 'Server D',
            AccountId = acc.Id,
            Product2Id = prod.Id,
            UsageEndDate = Date.today().addMonths(9),
            Price = 2000
        );
        insert new List<Asset>{ earlier, later };

        // Act — group both into a single renewal
        List<Id> assetIds = new List<Id>{ earlier.Id, later.Id };
        Test.startTest();
        Id oppId = AssetTimelineController.createRenewalOpportunities(acc.Id, assetIds);
        Test.stopTest();

        // Assert — exactly ONE grouped Opportunity with summed fields
        List<Opportunity> opps = [
            SELECT Id, Name, CloseDate, Amount, AccountId
            FROM Opportunity
            WHERE AccountId = :acc.Id
        ];
        Assert.areEqual(1, opps.size(), 'Exactly one grouped Opportunity should be created.');
        Opportunity grouped = opps[0];
        Assert.areEqual('Test Account - Renewal - ' + monthYear(earlier.UsageEndDate), grouped.Name);
        Assert.areEqual(
            earlier.UsageEndDate,
            grouped.CloseDate,
            'CloseDate should be the earliest expiry.'
        );
        Assert.areEqual(3000, grouped.Amount, 'Amount should be the sum of Asset prices.');

        // Assert — BOTH Assets linked to the same grouped Opportunity
        List<Asset> updated = [
            SELECT Id, Renewal_Opportunity__c
            FROM Asset
            WHERE Id IN :assetIds
        ];
        for (Asset a : updated) {
            Assert.areEqual(
                oppId,
                a.Renewal_Opportunity__c,
                'Every selected Asset must be linked to the grouped Opportunity.'
            );
        }

        // Assert — every renewed Product is on the Opportunity as a line item
        List<OpportunityLineItem> olis = [
            SELECT Id, Quantity, UnitPrice
            FROM OpportunityLineItem
            WHERE OpportunityId = :oppId
        ];
        Assert.areEqual(2, olis.size(), 'One line item per renewed Asset should be created.');
        Assert.areEqual(3000, olis[0].UnitPrice + olis[1].UnitPrice);
    }

    /**
     * @description Formats a Date as "MMM yyyy" to match the controller's
     *              Opportunity naming pattern.
     */
    private static String monthYear(Date d) {
        List<String> months = new List<String>{
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        };
        return months[d.month() - 1] + ' ' + d.year();
    }
}
