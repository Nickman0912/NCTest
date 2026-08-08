/**
 * @description Unit tests for InsideSalesAIController.
 *              Covers context gathering, nearby-school whitespace detection,
 *              and the OpenRouter callout (mocked).
 */
@isTest
private class InsideSalesAIControllerTest {

    /** Mock HTTP callout for OpenRouter. */
    private class OpenRouterMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(
                '{"choices":[{"message":{"role":"assistant","content":"Raptor AI here! This school has 3 assets expiring soon."}}]}'
            );
            return res;
        }
    }

    /** Test setup: account (and parent district), products, assets. */
    @TestSetup
    static void setup() {
        // District + School record types
        Id schoolRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'School' LIMIT 1].Id;
        Id districtRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'District' LIMIT 1].Id;

        // District
        Account district = new Account(
            Name = 'Test District',
            RecordTypeId = districtRtId,
            BillingState = 'KY',
            BillingCity = 'Louisville'
        );
        insert district;

        // Current school (Louisville, KY)
        Account currentSchool = new Account(
            Name = 'Current Test High School',
            RecordTypeId = schoolRtId,
            ParentId = district.Id,
            School_Type__c = 'High School',
            Grades_Served__c = '9-12',
            Student_Population__c = 1500,
            Faculty_Size__c = 90,
            BillingState = 'KY',
            BillingCity = 'Louisville',
            Latitude__c = 38.2527,
            Longitude__c = -85.7585
        );
        insert currentSchool;

        // A sibling school in the same district (same ParentId), ~5 miles away
        Account siblingSchool = new Account(
            Name = 'Sibling Test Elementary',
            RecordTypeId = schoolRtId,
            ParentId = district.Id,
            School_Type__c = 'Elementary School',
            Grades_Served__c = 'K-5',
            Student_Population__c = 500,
            Faculty_Size__c = 35,
            BillingState = 'KY',
            BillingCity = 'Louisville',
            Latitude__c = 38.30,
            Longitude__c = -85.70
        );

        // Two nearby schools (same state, different district)
        Account nearbyA = new Account(
            Name = 'Nearby School A',
            RecordTypeId = schoolRtId,
            School_Type__c = 'High School',
            Grades_Served__c = '9-12',
            Student_Population__c = 1200,
            Faculty_Size__c = 80,
            BillingState = 'KY',
            BillingCity = 'Lexington',
            Latitude__c = 38.04,
            Longitude__c = -84.50
        );
        Account nearbyB = new Account(
            Name = 'Nearby School B',
            RecordTypeId = schoolRtId,
            School_Type__c = 'Middle School',
            Grades_Served__c = '6-8',
            Student_Population__c = 700,
            Faculty_Size__c = 50,
            BillingState = 'KY',
            BillingCity = 'Louisville'
        );
        insert new List<Account>{ siblingSchool, nearbyA, nearbyB };

        // Products
        Product2 productAlpha = new Product2(Name = 'Raptor Sales Solution', Family = 'Safety');
        Product2 productBeta = new Product2(Name = 'Raptor Analytics', Family = 'Analytics');
        insert new List<Product2>{ productAlpha, productBeta };

        // Assets on current school (self-purchased: Purchased_By__c null)
        Asset assetAlpha = new Asset(
            Name = 'Current School - Solution',
            AccountId = currentSchool.Id,
            Product2Id = productAlpha.Id,
            Status = 'Purchased',
            UsageEndDate = Date.today().addMonths(6),
            Price = 1000
        );
        // Nearby School A already has the same product (not a gap)
        Asset assetAlphaNearbyA = new Asset(
            Name = 'Nearby A - Solution',
            AccountId = nearbyA.Id,
            Product2Id = productAlpha.Id,
            Status = 'Purchased',
            UsageEndDate = Date.today().addMonths(12)
        );
        // Sibling school in the same district individually purchased the
        // Analytics product (Purchased_By__c = the sibling school itself).
        Asset assetBetaSibling = new Asset(
            Name = 'Sibling - Analytics',
            AccountId = siblingSchool.Id,
            Product2Id = productBeta.Id,
            Purchased_By__c = siblingSchool.Id,
            Status = 'Purchased',
            UsageEndDate = Date.today().addMonths(9)
        );
        insert new List<Asset>{ assetAlpha, assetAlphaNearbyA, assetBetaSibling };
    }

    /** Injects a test config override (MDT records cannot be DML'd in tests). */
    private static void setTestConfig(String apiKey) {
        InsideSalesAIController.testConfigOverride = new AI_Configuration__mdt(
            API_Key__c = apiKey,
            Model__c = 'anthropic/claude-3.5-sonnet',
            Endpoint__c = 'https://openrouter.ai/api/v1/chat/completions',
            Max_Tokens__c = 512,
            Temperature__c = 0.7,
            System_Prompt__c = 'You are Raptor AI, an inside sales assistant.',
            Is_Active__c = true
        );
    }

    /* ================= CONTEXT ================= */

    @isTest
    static void testGetAccountContext() {
        setTestConfig('test-openrouter-key');
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];

        Test.startTest();
        InsideSalesAIController.AccountContext ctx =
            InsideSalesAIController.getAccountContext(school.Id);
        Test.stopTest();

        System.assertEquals('Current Test High School', ctx.accountName, 'Account name should match');
        System.assertEquals('School', ctx.recordType, 'Record type should be School');
        System.assertEquals(1500, ctx.studentPopulation, 'Student population should match');
        System.assert(ctx.assets.size() > 0, 'Expected at least one asset');
        System.assertEquals(true, ctx.configReady, 'Config should be ready');
        System.assert(ctx.nearbySchools.size() >= 0, 'Nearby schools should be computed');
    }

    @isTest
    static void testGetAccountContext_rejectsNonAccount() {
        try {
            InsideSalesAIController.getAccountContext(null);
            System.assert(false, 'Expected exception for null Id');
        } catch (AuraHandledException e) {
            System.assert(true, 'Exception thrown as expected');
        }
    }

    /* ================= DISTRICT SCHOOLS ================= */

    @isTest
    static void testGetAccountContext_districtSchools() {
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];
        Account sibling = [SELECT Id FROM Account WHERE Name = 'Sibling Test Elementary' LIMIT 1];

        Test.startTest();
        InsideSalesAIController.AccountContext ctx =
            InsideSalesAIController.getAccountContext(school.Id);
        Test.stopTest();

        // The sibling in the same district should appear, but NOT the
        // nearby schools from other districts.
        System.assertEquals(1, ctx.districtSchools.size(),
            'Should find exactly one other school in the same district');

        InsideSalesAIController.DistrictSchool ds = ctx.districtSchools[0];
        System.assertEquals(sibling.Id, ds.accountId, 'Should be the sibling school');
        System.assertEquals('Sibling Test Elementary', ds.name, 'Name should match');
        System.assertEquals('Elementary School', ds.schoolType, 'School type should match');
        System.assertEquals(500, ds.studentPopulation, 'Student population should match');
        System.assert(ds.products.contains('Raptor Analytics'),
            'Sibling should have the Analytics product listed');
        System.assert(ds.individuallyPurchasedProducts != null
            && ds.individuallyPurchasedProducts.contains('Raptor Analytics'),
            'Sibling should have the Analytics product listed as individually purchased');
        // Sibling is ~5 miles from the current school (both have coordinates).
        System.assertNotEquals(null, ds.distanceMiles, 'Distance should be computed');
        System.assert(ds.distanceMiles > 0 && ds.distanceMiles < 10,
            'Sibling should be a few miles away, got ' + ds.distanceMiles);
    }

    @isTest
    static void testGetAccountContext_districtSchools_emptyForLoneSchool() {
        Account nearbyB = [SELECT Id FROM Account WHERE Name = 'Nearby School B' LIMIT 1];

        Test.startTest();
        InsideSalesAIController.AccountContext ctx =
            InsideSalesAIController.getAccountContext(nearbyB.Id);
        Test.stopTest();

        // Nearby School B has no ParentId (no district), so no district schools.
        System.assert(ctx.districtSchools == null || ctx.districtSchools.isEmpty(),
            'School with no district should have no district siblings');
    }

    /* ================= NEARBY SCHOOLS ================= */

    @isTest
    static void testFindNearbySchools_whitespaceGap() {
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];
        Account nearbyB = [SELECT Id FROM Account WHERE Name = 'Nearby School B' LIMIT 1];

        Test.startTest();
        List<InsideSalesAIController.NearbySchool> nearby =
            InsideSalesAIController.findNearbySchools(school.Id);
        Test.stopTest();

        // Nearby School A already has the solution product → not a target.
        // Nearby School B has no products → should be a target missing the solution.
        Boolean foundB = false;
        for (InsideSalesAIController.NearbySchool ns : nearby) {
            if (ns.accountId == nearbyB.Id) {
                foundB = true;
                System.assert(ns.missingProducts.size() > 0, 'Nearby B should be missing products');
                // Nearby B has no coordinates, so distance should be null.
                System.assertEquals(null, ns.distanceMiles,
                    'Nearby B has no coordinates so distance should be null');
            }
        }
        System.assert(foundB, 'Nearby School B should appear as a whitespace target');
    }

    /* ================= RENEWAL OPPORTUNITY ================= */

    @isTest
    static void testCreateRenewalOpportunity_success() {
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE AccountId = :school.Id LIMIT 1];

        Test.startTest();
        InsideSalesAIController.RenewalResult result =
            InsideSalesAIController.createRenewalOpportunity(school.Id, new List<Id>{ asset.Id });
        Test.stopTest();

        System.assertEquals(true, result.success, 'Renewal should succeed');
        System.assertNotEquals(null, result.opportunityId, 'Should return an Opportunity Id');
        System.assert(String.isNotBlank(result.opportunityName), 'Should return the Opportunity name');
        System.assert(String.isNotBlank(result.message), 'Should return a message');
    }

    @isTest
    static void testCreateRenewalOpportunity_noAssets() {
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];

        InsideSalesAIController.RenewalResult result =
            InsideSalesAIController.createRenewalOpportunity(school.Id, new List<Id>());

        System.assertEquals(false, result.success, 'Should fail with no assets');
        System.assert(String.isNotBlank(result.message), 'Should return an error message');
    }

    @isTest
    static void testCreateRenewalOpportunity_duplicate() {
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];
        Asset asset = [SELECT Id FROM Asset WHERE AccountId = :school.Id LIMIT 1];

        // First creation succeeds
        InsideSalesAIController.createRenewalOpportunity(school.Id, new List<Id>{ asset.Id });

        // Second creation should fail gracefully (not throw)
        InsideSalesAIController.RenewalResult result =
            InsideSalesAIController.createRenewalOpportunity(school.Id, new List<Id>{ asset.Id });

        System.assertEquals(false, result.success, 'Duplicate renewal should fail');
        System.assert(String.isNotBlank(result.message), 'Should return an error message');
    }

    /* ================= PURCHASED BY ================= */

    @isTest
    static void testGetAccountContext_showsPurchasedBy() {
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];
        Account district = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];

        // Create an externally purchased asset
        Product2 prod = [SELECT Id FROM Product2 WHERE Name = 'Raptor Analytics' LIMIT 1];
        Asset external = new Asset(
            Name = 'Externally Purchased Asset',
            AccountId = school.Id,
            Product2Id = prod.Id,
            Purchased_By__c = district.Id,
            UsageEndDate = Date.today().addMonths(3),
            Price = 500
        );
        insert external;

        Test.startTest();
        InsideSalesAIController.AccountContext ctx =
            InsideSalesAIController.getAccountContext(school.Id);
        Test.stopTest();

        // Find the externally purchased asset in context
        InsideSalesAIController.AssetInfo extInfo = null;
        for (InsideSalesAIController.AssetInfo info : ctx.assets) {
            if (info.assetId == external.Id) {
                extInfo = info;
            }
        }

        System.assertNotEquals(null, extInfo, 'Externally purchased asset should be in context');
        System.assertEquals(false, extInfo.isSelfPurchased, 'Should not be self-purchased');
        System.assertEquals('Test District', extInfo.purchasedBy, 'Should show the purchaser account name');
    }

    /* ================= CHAT (MOCKED CALLOUT) ================= */

    @isTest
    static void testChat_callsOpenRouter() {
        setTestConfig('test-openrouter-key');
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new OpenRouterMock());

        Test.startTest();
        InsideSalesAIController.ChatResponse resp =
            InsideSalesAIController.chat(school.Id, 'What is the whitespace?', null);
        Test.stopTest();

        System.assertNotEquals(null, resp, 'Response should not be null');
        System.assert(String.isNotBlank(resp.reply), 'Reply should not be blank');
        System.assert(resp.reply.contains('Raptor AI'), 'Reply should contain mocked content');
    }

    @isTest
    static void testChat_missingApiKey() {
        // Override with a blank/placeholder key
        setTestConfig('YOUR_OPENROUTER_API_KEY');
        Account school = [SELECT Id FROM Account WHERE Name = 'Current Test High School' LIMIT 1];

        try {
            InsideSalesAIController.chat(school.Id, 'hello', null);
            System.assert(false, 'Expected exception when API key not set');
        } catch (AuraHandledException e) {
            System.assert(true, 'Exception thrown when API key not configured');
        }
    }
}