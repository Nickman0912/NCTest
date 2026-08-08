/**
 * @description Unit tests for OpportunityProductCoverageController.
 */
@isTest
private class OpportunityProductCoverageControllerTest {

    @TestSetup
    static void setupData() {
        // Record Types
        Id jpaRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('JPA').getRecordTypeId();
        Id districtRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('District').getRecordTypeId();
        Id schoolRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('School').getRecordTypeId();

        // Hierarchy: JPA (top) → District → School
        Account jpa = new Account(Name = 'Test JPA', RecordTypeId = jpaRtId);
        insert jpa;

        Account district = new Account(Name = 'Test District', RecordTypeId = districtRtId);
        insert district;

        Account school = new Account(Name = 'Test School', RecordTypeId = schoolRtId, ParentId = district.Id);
        insert school;

        // Relationship: District (child) → JPA (parent)
        insert new Relationship__c(
            Primary_Account__c = district.Id,
            Secondary_Account__c = jpa.Id,
            Relationship_Type__c = 'Product Line Alpha'
        );

        // Product + pricebook entry
        Product2 prod = new Product2(
            Name = 'Product Alpha',
            ProductCode = 'PA-001',
            Family = 'Software',
            IsActive = true
        );
        insert prod;

        Id pricebookId = Test.getStandardPricebookId();
        insert new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = prod.Id,
            UnitPrice = 1000,
            IsActive = true
        );

        // Opportunity on the JPA with a line item
        Opportunity opp = new Opportunity(
            Name = 'Test Deal',
            AccountId = jpa.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = pricebookId
        );
        insert opp;

        insert new OpportunityLineItem(
            OpportunityId = opp.Id,
            PricebookEntryId = [SELECT Id FROM PricebookEntry WHERE Product2Id = :prod.Id LIMIT 1].Id,
            Quantity = 5,
            UnitPrice = 1000
        );

        // Assets: District owns the product, School does not
        insert new Asset(
            Name = 'District Asset',
            AccountId = district.Id,
            Product2Id = prod.Id,
            Status = 'Installed',
            Quantity = 2
        );
    }

    @isTest
    static void testProductCoverageFindsDescendantOwners() {
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'Test Deal' LIMIT 1];

        Test.startTest();
        OpportunityProductCoverageController.CoverageResult result =
            OpportunityProductCoverageController.getProductCoverage(opp.Id);
        Test.stopTest();

        // JPA (self) + District + School = 3 accounts
        System.assertEquals(3, result.totalAccounts, 'Expected 3 accounts in hierarchy.');
        // Only District owns the product
        System.assertEquals(1, result.totalAccountsWithOwnership, 'Expected 1 account with ownership.');
        System.assertEquals(1, result.totalMatchingAssets, 'Expected 1 matching asset.');

        // Product coverage
        System.assertEquals(1, result.products.size());
        System.assertEquals('Product Alpha', result.products[0].productName);
        System.assertEquals(1, result.products[0].ownerCount);
        System.assertEquals(1, result.products[0].assetCount);

        // Hierarchy accounts sorted by depth: self (0), district (1), school (2)
        System.assertEquals('Test JPA', result.hierarchyAccounts[0].name);
        System.assertEquals(true, result.hierarchyAccounts[0].isSelf);
        System.assertEquals(0, result.hierarchyAccounts[0].depth);
        System.assertEquals(0, result.hierarchyAccounts[0].ownedAssets.size());

        // District is depth 1 and owns the asset
        OpportunityProductCoverageController.HierarchyAccount districtNode =
            result.hierarchyAccounts[1];
        System.assertEquals('Test District', districtNode.name);
        System.assertEquals(1, districtNode.depth);
        System.assertEquals('Test JPA', districtNode.parentName);
        System.assertEquals(1, districtNode.ownedAssets.size());
        System.assertEquals('District Asset', districtNode.ownedAssets[0].name);
        System.assertEquals('Installed', districtNode.ownedAssets[0].status);

        // School is depth 2, no assets
        OpportunityProductCoverageController.HierarchyAccount schoolNode =
            result.hierarchyAccounts[2];
        System.assertEquals('Test School', schoolNode.name);
        System.assertEquals(2, schoolNode.depth);
        System.assertEquals('Test District', schoolNode.parentName);
        System.assertEquals(0, schoolNode.ownedAssets.size());
    }

    @isTest
    static void testNoLineItemsReturnsEmpty() {
        // Create an opportunity with no line items
        Account jpa = [SELECT Id FROM Account WHERE Name = 'Test JPA' LIMIT 1];
        Id pricebookId = Test.getStandardPricebookId();
        Opportunity emptyOpp = new Opportunity(
            Name = 'Empty Deal',
            AccountId = jpa.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = pricebookId
        );
        insert emptyOpp;

        Test.startTest();
        OpportunityProductCoverageController.CoverageResult result =
            OpportunityProductCoverageController.getProductCoverage(emptyOpp.Id);
        Test.stopTest();

        System.assertEquals(0, result.products.size());
        System.assertEquals(0, result.hierarchyAccounts.size());
        System.assertEquals(0, result.totalAccounts);
    }

    @isTest
    static void testSelfOwnershipCounted() {
        // Give the JPA itself an asset too
        Account jpa = [SELECT Id FROM Account WHERE Name = 'Test JPA' LIMIT 1];
        Product2 prod = [SELECT Id FROM Product2 WHERE Name = 'Product Alpha' LIMIT 1];
        insert new Asset(
            Name = 'JPA Asset',
            AccountId = jpa.Id,
            Product2Id = prod.Id,
            Status = 'Purchased',
            Quantity = 1
        );

        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'Test Deal' LIMIT 1];

        Test.startTest();
        OpportunityProductCoverageController.CoverageResult result =
            OpportunityProductCoverageController.getProductCoverage(opp.Id);
        Test.stopTest();

        // JPA + District now own it
        System.assertEquals(2, result.totalAccountsWithOwnership);
        System.assertEquals(2, result.products[0].ownerCount);
        System.assertEquals(2, result.products[0].assetCount);

        // Self node has the asset
        System.assertEquals(1, result.hierarchyAccounts[0].ownedAssets.size());
        System.assertEquals('JPA Asset', result.hierarchyAccounts[0].ownedAssets[0].name);
    }
}