/**
 * @description Resolves Account billing addresses to latitude/longitude via the
 *              Google Maps Geocoding API and caches the result on the Account.
 *              Used by InsideSalesAIController to compute distances between schools.
 *
 *              Two usage modes:
 *              1. Synchronous (chat): geocodeForChat() performs the HTTP callouts
 *                 and returns coordinates WITHOUT DML, so the caller can make its
 *                 own callout (OpenRouter) before persisting via
 *                 persistGeocodeResults(). This avoids the "uncommitted work
 *                 pending" error (callout after DML in the same transaction).
 *              2. Asynchronous (load): implements Queueable so geocoding runs in
 *                 its own transaction via enqueueGeocoding().
 */
public with sharing class GeocodingService implements Queueable {

    /** Status values stored on Account.Geocode_Status__c. */
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_NO_ADDRESS = 'No Address';
    public static final String STATUS_NO_RESULT = 'No Result';
    public static final String STATUS_ERROR = 'Error';

    /** Test-only override so tests can inject a config without DML (MDT is not DML-able). */
    @TestVisible
    private static Geocoding_Configuration__mdt testConfigOverride;

    /** Account Ids to geocode when this job runs. */
    private Set<Id> accountIds;

    /** Default constructor for Queueable instantiation. */
    public GeocodingService() {
        this.accountIds = new Set<Id>();
    }

    /** Constructor with the account Ids to geocode. */
    public GeocodingService(Set<Id> ids) {
        this.accountIds = ids != null ? ids : new Set<Id>();
    }

    /** A geocoding result for a single account (no DML performed). */
    public class GeocodeResult {
        public Decimal latitude;
        public Decimal longitude;
        public String status;
    }

    /**
     * @description Enqueues a geocoding job for the given accounts. Safe to call
     *              with an empty set. The job runs asynchronously in its own
     *              transaction.
     * @param accountIds The Account Ids to geocode.
     */
    public static void enqueueGeocoding(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }
        System.enqueueJob(new GeocodingService(accountIds));
    }

    /**
     * @description Queueable entry point. Geocodes the queued accounts and
     *              persists the results. Runs in its own transaction.
     */
    public void execute(QueueableContext context) {
        geocodeAccounts(this.accountIds);
    }

    /**
     * @description Geocodes any of the given accounts that do not already have
     *              cached coordinates and persists the results. Safe to call with
     *              an empty list.
     * @param ids The Account Ids to geocode.
     */
    public static void geocodeAccounts(Set<Id> ids) {
        Map<Id, GeocodeResult> results = geocodeForChat(ids);
        persistGeocodeResults(results);
    }

    /**
     * @description Performs geocoding HTTP callouts for accounts that need
     *              coordinates and returns the results WITHOUT any DML. The caller
     *              is responsible for persisting via persistGeocodeResults() after
     *              its own callouts. Accounts already cached, or previously failed,
     *              are skipped (no callout).
     * @param ids The Account Ids to geocode.
     * @return Map of Account Id -> GeocodeResult for accounts that were geocoded.
     */
    public static Map<Id, GeocodeResult> geocodeForChat(Set<Id> ids) {
        Map<Id, GeocodeResult> results = new Map<Id, GeocodeResult>();
        if (ids == null || ids.isEmpty()) {
            return results;
        }

        Geocoding_Configuration__mdt config = getActiveConfig();
        if (config == null || String.isBlank(config.API_Key__c)
            || config.API_Key__c == 'YOUR_GOOGLE_MAPS_API_KEY') {
            return results; // Not configured — skip silently.
        }

        // Load accounts that need geocoding (no coords yet and not already failed).
        Map<Id, Account> toGeocode = new Map<Id, Account>();
        for (Account a : [
            SELECT Id, Name, BillingStreet, BillingCity, BillingState,
                   BillingPostalCode, BillingCountry,
                   Latitude__c, Longitude__c, Geocode_Status__c
            FROM Account
            WHERE Id IN :ids
        ]) {
            if (a.Latitude__c != null && a.Longitude__c != null) {
                continue; // Already cached.
            }
            if (a.Geocode_Status__c == STATUS_NO_ADDRESS
                || a.Geocode_Status__c == STATUS_NO_RESULT
                || a.Geocode_Status__c == STATUS_ERROR) {
                continue; // Previously failed — don't hammer the API.
            }
            toGeocode.put(a.Id, a);
        }
        if (toGeocode.isEmpty()) {
            return results;
        }

        for (Account a : toGeocode.values()) {
            String address = buildAddress(a);
            if (String.isBlank(address)) {
                GeocodeResult r = new GeocodeResult();
                r.status = STATUS_NO_ADDRESS;
                results.put(a.Id, r);
                continue;
            }

            try {
                GeocodeResult geo = callGeocode(config, address);
                if (geo.latitude != null && geo.longitude != null) {
                    geo.status = STATUS_SUCCESS;
                } else {
                    geo.status = STATUS_NO_RESULT;
                }
                results.put(a.Id, geo);
            } catch (Exception e) {
                GeocodeResult r = new GeocodeResult();
                r.status = STATUS_ERROR;
                results.put(a.Id, r);
            }
        }
        return results;
    }

    /**
     * @description Persists geocoding results to the Account records (DML).
     *              Call this AFTER any other callouts in the transaction to avoid
     *              the "uncommitted work pending" error.
     * @param results Map of Account Id -> GeocodeResult to persist.
     */
    public static void persistGeocodeResults(Map<Id, GeocodeResult> results) {
        if (results == null || results.isEmpty()) {
            return;
        }

        List<Account> updates = new List<Account>();
        for (Id acctId : results.keySet()) {
            GeocodeResult r = results.get(acctId);
            Account a = new Account(Id = acctId);
            a.Geocode_Status__c = r.status;
            a.Geocoded_On__c = System.now();
            if (r.latitude != null && r.longitude != null) {
                a.Latitude__c = r.latitude;
                a.Longitude__c = r.longitude;
            }
            updates.add(a);
        }

        if (!updates.isEmpty()) {
            update updates;
        }
    }

    /** Builds a single-line address from the billing fields. */
    private static String buildAddress(Account a) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(a.BillingStreet)) parts.add(a.BillingStreet);
        if (String.isNotBlank(a.BillingCity)) parts.add(a.BillingCity);
        if (String.isNotBlank(a.BillingState)) parts.add(a.BillingState);
        if (String.isNotBlank(a.BillingPostalCode)) parts.add(a.BillingPostalCode);
        if (String.isNotBlank(a.BillingCountry)) parts.add(a.BillingCountry);
        return String.join(parts, ', ');
    }

    /** Calls the Google Maps Geocoding API for a single address. */
    private static GeocodeResult callGeocode(Geocoding_Configuration__mdt config, String address) {
        String endpoint = String.isNotBlank(config.Endpoint__c)
            ? config.Endpoint__c.trim()
            : 'https://maps.googleapis.com/maps/api/geocode/json';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint + '?address=' + EncodingUtil.urlEncode(address, 'UTF-8')
            + '&key=' + config.API_Key__c.trim());
        req.setMethod('GET');
        req.setTimeout(20000);

        Http http = new Http();
        HttpResponse res = http.send(req);

        GeocodeResult result = new GeocodeResult();

        if (res.getStatusCode() != 200) {
            return result;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String status = String.valueOf(body.get('status'));
        if (status != 'OK') {
            return result;
        }

        List<Object> results = (List<Object>) body.get('results');
        if (results == null || results.isEmpty()) {
            return result;
        }

        Map<String, Object> first = (Map<String, Object>) results[0];
        Map<String, Object> geometry = (Map<String, Object>) first.get('geometry');
        if (geometry == null) {
            return result;
        }
        Map<String, Object> location = (Map<String, Object>) geometry.get('location');
        if (location == null) {
            return result;
        }

        result.latitude = Decimal.valueOf(String.valueOf(location.get('lat')));
        result.longitude = Decimal.valueOf(String.valueOf(location.get('lng')));
        return result;
    }

    /** Retrieves the active Geocoding_Configuration__mdt record. */
    private static Geocoding_Configuration__mdt getActiveConfig() {
        if (testConfigOverride != null) {
            return testConfigOverride;
        }
        List<Geocoding_Configuration__mdt> configs = [
            SELECT Id, API_Key__c, Endpoint__c, Provider__c, Is_Active__c
            FROM Geocoding_Configuration__mdt
            WHERE Is_Active__c = true
            LIMIT 1
        ];
        return configs.isEmpty() ? null : configs[0];
    }
}