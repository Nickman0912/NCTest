/**
 * @description Unit test class for OpportunityTrigger, OpportunityTriggerHandler, and OpportunityService.
 */
@IsTest
private class OpportunityTriggerTest {

    @TestSetup
    static void setupTestData() {
        // RecordType IDs
        Id jpaRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'JPA' LIMIT 1].Id;
        Id districtRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'District' LIMIT 1].Id;
        Id schoolRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'School' LIMIT 1].Id;
        Id raptorRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Raptor_Sale' LIMIT 1].Id;

        // Bypass Duplicate Rules for test data creation
        Database.DMLOptions dmlOpt = new Database.DMLOptions();
        dmlOpt.DuplicateRuleHeader.allowSave = true;
        dmlOpt.DuplicateRuleHeader.runAsCurrentUser = true;

        // Create JPA Account (Secondary)
        Account jpaAccount = new Account(
            Name = 'Test JPA Account',
            RecordTypeId = jpaRtId
        );
        Database.insert(jpaAccount, dmlOpt);

        // Create District Account (Primary)
        Account districtAccount = new Account(
            Name = 'Test District Account',
            RecordTypeId = districtRtId
        );
        Database.insert(districtAccount, dmlOpt);

        // Create 2 Child School Accounts
        List<Account> schools = new List<Account>{
            new Account(Name = 'Test School 1', RecordTypeId = schoolRtId, ParentId = districtAccount.Id),
            new Account(Name = 'Test School 2', RecordTypeId = schoolRtId, ParentId = districtAccount.Id)
        };
        Database.insert(schools, dmlOpt);

        // Create Relationship__c junction record (District -> JPA with 'Liability' type)
        Relationship__c rel = new Relationship__c(
            Primary_Account__c = districtAccount.Id,
            Secondary_Account__c = jpaAccount.Id,
            Relationship_Type__c = 'Liability'
        );
        insert rel;

        // Create Product2
        Product2 prod = new Product2(
            Name = 'Liability',
            IsActive = true
        );
        insert prod;

        // Create Opportunity (Prospecting stage)
        Opportunity opp = new Opportunity(
            Name = 'Test Liability Deal',
            AccountId = jpaAccount.Id,
            RecordTypeId = raptorRtId,
            Relationship_Type__c = 'Liability',
            StageName = 'Prospecting',
            Amount = 50000,
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
    }

    @IsTest
    static void testCascadeAssetsOnClosedWon() {
        Opportunity opp = [SELECT Id, StageName FROM Opportunity WHERE Name = 'Test Liability Deal' LIMIT 1];

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        // Verify Assets created: 1 for JPA Account, 1 for District Account, 2 for Child Schools = 4 Assets total
        List<Asset> createdAssets = [SELECT Id, Name, AccountId, Purchased_By__c, Product2Id, Status FROM Asset WHERE Status = 'Purchased'];
        Assert.areEqual(4, createdAssets.size(), 'Expected 4 Assets created for JPA, District, and 2 Schools');

        Account jpaAcc = [SELECT Id FROM Account WHERE Name = 'Test JPA Account' LIMIT 1];
        Account distAcc = [SELECT Id FROM Account WHERE Name = 'Test District Account' LIMIT 1];

        Set<Id> accountIdsWithAssets = new Set<Id>();
        for (Asset a : createdAssets) {
            accountIdsWithAssets.add(a.AccountId);
            Assert.areEqual('Purchased', a.Status, 'Asset status should be Purchased');
            Assert.areEqual(jpaAcc.Id, a.Purchased_By__c, 'Purchased_By__c should match originating JPA Account ID');
        }

        Assert.isTrue(accountIdsWithAssets.contains(jpaAcc.Id), 'Asset should exist for JPA Account');
        Assert.isTrue(accountIdsWithAssets.contains(distAcc.Id), 'Asset should exist for District Account');
    }

    @IsTest
    static void testNonMatchingRelationshipTypeDoesNotCascade() {
        Account jpaAccount = [SELECT Id FROM Account WHERE Name = 'Test JPA Account' LIMIT 1];
        Id raptorRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Raptor_Sale' LIMIT 1].Id;

        // Create Opp with non-matching relationship type 'Product Line Beta'
        Opportunity opp = new Opportunity(
            Name = 'Test Non-Matching Deal',
            AccountId = jpaAccount.Id,
            RecordTypeId = raptorRtId,
            Relationship_Type__c = 'Product Line Beta',
            StageName = 'Prospecting',
            Amount = 25000,
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Test.startTest();
        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        // Only 1 Asset should be created for the JPA Account directly (no relationships match 'Product Line Beta')
        List<Asset> assets = [SELECT Id, AccountId, Purchased_By__c FROM Asset WHERE Name LIKE 'Test Non-Matching Deal%'];
        Assert.areEqual(1, assets.size(), 'Expected only 1 direct Asset for the JPA Account');
        Assert.areEqual(jpaAccount.Id, assets[0].AccountId, 'Asset should belong to JPA Account');
        Assert.areEqual(jpaAccount.Id, assets[0].Purchased_By__c, 'Purchased_By__c should match originating JPA Account ID');
    }
}
