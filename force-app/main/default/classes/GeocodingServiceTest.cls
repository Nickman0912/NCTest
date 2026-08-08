/**
 * @description Unit tests for GeocodingService.
 *              Covers successful geocoding, caching, and failure paths.
 */
@isTest
private class GeocodingServiceTest {

    /** Mock HTTP callout for the Google Maps Geocoding API. */
    private class GeocodeMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(
                '{"results":[{"geometry":{"location":{"lat":38.2527,"lng":-85.7585}}}],"status":"OK"}'
            );
            return res;
        }
    }

    /** Mock that returns a non-OK status (no result). */
    private class GeocodeNoResultMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"results":[],"status":"ZERO_RESULTS"}');
            return res;
        }
    }

    /** Injects a test config override (MDT records cannot be DML'd in tests). */
    private static void setTestConfig() {
        GeocodingService.testConfigOverride = new Geocoding_Configuration__mdt(
            API_Key__c = 'test-google-key',
            Endpoint__c = 'https://maps.googleapis.com/maps/api/geocode/json',
            Provider__c = 'Google Maps',
            Is_Active__c = true
        );
    }

    @isTest
    static void testGeocodeAccounts_success() {
        setTestConfig();
        Account school = new Account(
            Name = 'Geocode Test School',
            BillingStreet = '123 Main St',
            BillingCity = 'Louisville',
            BillingState = 'KY',
            BillingPostalCode = '40202'
        );
        insert school;

        Test.setMock(HttpCalloutMock.class, new GeocodeMock());

        Test.startTest();
        GeocodingService.geocodeAccounts(new Set<Id>{ school.Id });
        Test.stopTest();

        Account updated = [SELECT Id, Latitude__c, Longitude__c, Geocode_Status__c, Geocoded_On__c
                           FROM Account WHERE Id = :school.Id];
        System.assertEquals(38.2527, updated.Latitude__c, 'Latitude should be written');
        System.assertEquals(-85.7585, updated.Longitude__c, 'Longitude should be written');
        System.assertEquals(GeocodingService.STATUS_SUCCESS, updated.Geocode_Status__c,
            'Status should be Success');
        System.assertNotEquals(null, updated.Geocoded_On__c, 'Geocoded timestamp should be set');
    }

    @isTest
    static void testGeocodeAccounts_skipsCached() {
        setTestConfig();
        Account school = new Account(
            Name = 'Cached School',
            BillingCity = 'Louisville',
            BillingState = 'KY',
            Latitude__c = 38.25,
            Longitude__c = -85.75
        );
        insert school;

        // If the cache is respected, no callout should be made.
        Test.setMock(HttpCalloutMock.class, new GeocodeMock());

        Test.startTest();
        GeocodingService.geocodeAccounts(new Set<Id>{ school.Id });
        Test.stopTest();

        Account updated = [SELECT Id, Latitude__c, Longitude__c, Geocode_Status__c
                           FROM Account WHERE Id = :school.Id];
        System.assertEquals(38.25, updated.Latitude__c, 'Cached latitude should be unchanged');
        System.assertEquals(-85.75, updated.Longitude__c, 'Cached longitude should be unchanged');
        System.assertEquals(null, updated.Geocode_Status__c, 'No status should be written for cached');
    }

    @isTest
    static void testGeocodeAccounts_noAddress() {
        setTestConfig();
        Account school = new Account(Name = 'No Address School');
        insert school;

        Test.setMock(HttpCalloutMock.class, new GeocodeMock());

        Test.startTest();
        GeocodingService.geocodeAccounts(new Set<Id>{ school.Id });
        Test.stopTest();

        Account updated = [SELECT Id, Geocode_Status__c FROM Account WHERE Id = :school.Id];
        System.assertEquals(GeocodingService.STATUS_NO_ADDRESS, updated.Geocode_Status__c,
            'Status should be No Address');
    }

    @isTest
    static void testGeocodeAccounts_noResult() {
        setTestConfig();
        Account school = new Account(
            Name = 'No Result School',
            BillingCity = 'Nowhere',
            BillingState = 'XX'
        );
        insert school;

        Test.setMock(HttpCalloutMock.class, new GeocodeNoResultMock());

        Test.startTest();
        GeocodingService.geocodeAccounts(new Set<Id>{ school.Id });
        Test.stopTest();

        Account updated = [SELECT Id, Geocode_Status__c FROM Account WHERE Id = :school.Id];
        System.assertEquals(GeocodingService.STATUS_NO_RESULT, updated.Geocode_Status__c,
            'Status should be No Result');
    }

    @isTest
    static void testGeocodeForChat_returnsResultsWithoutDML() {
        setTestConfig();
        Account school = new Account(
            Name = 'Geocode For Chat School',
            BillingCity = 'Louisville',
            BillingState = 'KY'
        );
        insert school;

        Test.setMock(HttpCalloutMock.class, new GeocodeMock());

        Test.startTest();
        Map<Id, GeocodingService.GeocodeResult> results =
            GeocodingService.geocodeForChat(new Set<Id>{ school.Id });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assert(results.containsKey(school.Id), 'Result should be for the school');
        GeocodingService.GeocodeResult r = results.get(school.Id);
        System.assertEquals(38.2527, r.latitude, 'Latitude should match');
        System.assertEquals(-85.7585, r.longitude, 'Longitude should match');
        System.assertEquals(GeocodingService.STATUS_SUCCESS, r.status, 'Status should be Success');

        // Verify no DML was performed yet.
        Account unchanged = [SELECT Latitude__c, Longitude__c, Geocode_Status__c
                             FROM Account WHERE Id = :school.Id];
        System.assertEquals(null, unchanged.Latitude__c, 'Should NOT have been persisted yet');
        System.assertEquals(null, unchanged.Geocode_Status__c, 'Should NOT have been persisted yet');
    }

    @isTest
    static void testPersistGeocodeResults_writesToAccount() {
        setTestConfig();
        Account school = new Account(
            Name = 'Persist Test School',
            BillingCity = 'Louisville',
            BillingState = 'KY'
        );
        insert school;

        // Simulate a geocode result (no actual callout needed for persist test).
        Map<Id, GeocodingService.GeocodeResult> results = new Map<Id, GeocodingService.GeocodeResult>();
        GeocodingService.GeocodeResult r = new GeocodingService.GeocodeResult();
        r.latitude = 38.25;
        r.longitude = -85.75;
        r.status = GeocodingService.STATUS_SUCCESS;
        results.put(school.Id, r);

        Test.startTest();
        GeocodingService.persistGeocodeResults(results);
        Test.stopTest();

        Account updated = [SELECT Latitude__c, Longitude__c, Geocode_Status__c, Geocoded_On__c
                           FROM Account WHERE Id = :school.Id];
        System.assertEquals(38.25, updated.Latitude__c, 'Latitude should be persisted');
        System.assertEquals(-85.75, updated.Longitude__c, 'Longitude should be persisted');
        System.assertEquals(GeocodingService.STATUS_SUCCESS, updated.Geocode_Status__c,
            'Status should be persisted');
        System.assertNotEquals(null, updated.Geocoded_On__c, 'Timestamp should be set');
    }

    @isTest
    static void testEnqueueGeocoding_runsJob() {
        setTestConfig();
        Account school = new Account(
            Name = 'Enqueue School',
            BillingCity = 'Louisville',
            BillingState = 'KY'
        );
        insert school;

        Test.setMock(HttpCalloutMock.class, new GeocodeMock());

        Test.startTest();
        // Execute the queueable synchronously (static overrides are reset in
        // true async contexts, so we invoke execute() directly to verify the
        // job logic end-to-end).
        new GeocodingService(new Set<Id>{ school.Id }).execute(null);
        Test.stopTest();

        Account updated = [SELECT Id, Latitude__c, Longitude__c, Geocode_Status__c
                           FROM Account WHERE Id = :school.Id];
        System.assertEquals(38.2527, updated.Latitude__c, 'Queueable job should geocode the account');
        System.assertEquals(GeocodingService.STATUS_SUCCESS, updated.Geocode_Status__c,
            'Status should be Success after queued job');
    }

    @isTest
    static void testGeocodeAccounts_notConfigured() {
        // No config override set — the placeholder key path should skip silently.
        Account school = new Account(
            Name = 'Unconfigured School',
            BillingCity = 'Louisville',
            BillingState = 'KY'
        );
        insert school;

        Test.setMock(HttpCalloutMock.class, new GeocodeMock());

        Test.startTest();
        GeocodingService.geocodeAccounts(new Set<Id>{ school.Id });
        Test.stopTest();

        Account updated = [SELECT Id, Latitude__c, Geocode_Status__c FROM Account WHERE Id = :school.Id];
        System.assertEquals(null, updated.Latitude__c, 'No geocoding should occur when unconfigured');
        System.assertEquals(null, updated.Geocode_Status__c, 'No status should be written');
    }
}