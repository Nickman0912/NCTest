/**
 * @description Apex controller for the Inside Sales AI LWC.
 *              Gathers rich account context (assets, related accounts,
 *              nearby schools, product catalog) and calls the OpenRouter
 *              AI API to answer natural-language inside-sales questions.
 */
public with sharing class InsideSalesAIController {

    /* ================= WRAPPERS ================= */

    /** Full context payload sent to the AI as structured JSON. */
    public class AccountContext {
        @AuraEnabled public String accountName;
        @AuraEnabled public String recordType;
        @AuraEnabled public String schoolType;
        @AuraEnabled public String gradesServed;
        @AuraEnabled public Integer studentPopulation;
        @AuraEnabled public Integer facultySize;
        @AuraEnabled public String billingCity;
        @AuraEnabled public String billingState;
        @AuraEnabled public String billingPostalCode;
        @AuraEnabled public String parentName;
        @AuraEnabled public List<AssetInfo> assets;
        @AuraEnabled public List<RelatedAccount> relatedAccounts;
        @AuraEnabled public List<NearbySchool> nearbySchools;
        @AuraEnabled public List<DistrictSchool> districtSchools;
        @AuraEnabled public List<ProductInfo> productCatalog;
        @AuraEnabled public Boolean configReady;
        @AuraEnabled public String configModel;
    }

    /** Lightweight Asset representation. */
    public class AssetInfo {
        @AuraEnabled public String assetId;
        @AuraEnabled public String name;
        @AuraEnabled public String productName;
        @AuraEnabled public String productFamily;
        @AuraEnabled public String status;
        @AuraEnabled public Date expirationDate;
        @AuraEnabled public Decimal price;
        @AuraEnabled public String purchasedBy;
        @AuraEnabled public Boolean isSelfPurchased;
        @AuraEnabled public String renewalOpportunityId;
    }

    /** Related account (district, JPA, state entity). */
    public class RelatedAccount {
        @AuraEnabled public String accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String recordType;
        @AuraEnabled public String relationshipTypes;
    }

    /** A nearby school with its product gaps. */
    public class NearbySchool {
        @AuraEnabled public String accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String schoolType;
        @AuraEnabled public String gradesServed;
        @AuraEnabled public Integer studentPopulation;
        @AuraEnabled public Integer facultySize;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public Double distanceMiles;
        @AuraEnabled public List<String> existingProducts;
        @AuraEnabled public List<String> missingProducts;
    }

    /** A school within the same district as the current account. */
    public class DistrictSchool {
        @AuraEnabled public String accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String schoolType;
        @AuraEnabled public String gradesServed;
        @AuraEnabled public Integer studentPopulation;
        @AuraEnabled public Integer facultySize;
        @AuraEnabled public String city;
        @AuraEnabled public String state;
        @AuraEnabled public Double distanceMiles;
        @AuraEnabled public List<String> products;
        /** Products the school purchased for itself (Purchased_By__c is the school). */
        @AuraEnabled public List<String> individuallyPurchasedProducts;
    }

    /** Product catalog entry. */
    public class ProductInfo {
        @AuraEnabled public String productId;
        @AuraEnabled public String name;
        @AuraEnabled public String family;
    }

    /** The chat response returned to the LWC. */
    public class ChatResponse {
        @AuraEnabled public String reply;
        @AuraEnabled public String rawJson;
    }

    /** Result of a renewal opportunity creation request. */
    public class RenewalResult {
        @AuraEnabled public String opportunityId;
        @AuraEnabled public String opportunityName;
        @AuraEnabled public String message;
        @AuraEnabled public Boolean success;
    }

    /* ================= MAIN ENTRY POINTS ================= */

    /**
     * @description Gathers the full account context for the given Account.
     */
    @AuraEnabled(cacheable=true)
    public static AccountContext getAccountContext(Id accountId) {
        if (accountId == null || String.valueOf(accountId).startsWith('001') == false) {
            throw new AuraHandledException('A valid Account Id is required.');
        }

        AccountContext ctx = new AccountContext();
        ctx.configReady = true;
        ctx.configModel = '';

        // ---- Active AI config ----
        AI_Configuration__mdt config = getActiveConfig();
        if (config == null) {
            ctx.configReady = false;
        } else {
            ctx.configModel = config.Model__c;
        }

        // ---- Account + parent ----
        Account acct = [
            SELECT Id, Name, RecordType.DeveloperName,
                   School_Type__c, Grades_Served__c, Student_Population__c,
                   Faculty_Size__c, BillingCity, BillingState, BillingPostalCode,
                   ParentId, Parent.Name,
                   Latitude__c, Longitude__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        ctx.accountName = acct.Name;
        ctx.recordType = acct.RecordType != null ? acct.RecordType.DeveloperName : '';
        ctx.schoolType = acct.School_Type__c;
        ctx.gradesServed = acct.Grades_Served__c;
        ctx.studentPopulation = acct.Student_Population__c != null
            ? acct.Student_Population__c.intValue() : null;
        ctx.facultySize = acct.Faculty_Size__c != null
            ? acct.Faculty_Size__c.intValue() : null;
        ctx.billingCity = acct.BillingCity;
        ctx.billingState = acct.BillingState;
        ctx.billingPostalCode = acct.BillingPostalCode;
        ctx.parentName = acct.Parent != null ? acct.Parent.Name : '';

        // ---- Assets ----
        ctx.assets = new List<AssetInfo>();
        Map<Id, String> productNameById = new Map<Id, String>();
        for (Asset a : [
            SELECT Id, Name, Product2Id, Product2.Name, Product2.Family,
                   Status, UsageEndDate, Price,
                   Purchased_By__c, Purchased_By__r.Name,
                   Renewal_Opportunity__c
            FROM Asset
            WHERE AccountId = :accountId
            ORDER BY UsageEndDate ASC NULLS LAST, Name ASC
        ]) {
            ctx.assets.add(mapAsset(a, accountId, acct.Name));
            if (a.Product2Id != null) {
                productNameById.put(a.Product2Id, a.Product2.Name);
            }
        }

        // ---- Related accounts (via Relationship__c) ----
        ctx.relatedAccounts = new List<RelatedAccount>();
        Set<Id> relatedIds = new Set<Id>();
        // Relationships where this account is Primary (Secondary = parent/related)
        for (Relationship__c rel : [
            SELECT Secondary_Account__c, Secondary_Account__r.Name,
                   Secondary_Account__r.RecordType.DeveloperName,
                   Relationship_Type__c
            FROM Relationship__c
            WHERE Primary_Account__c = :accountId
        ]) {
            if (rel.Secondary_Account__c == null) continue;
            relatedIds.add(rel.Secondary_Account__c);
            RelatedAccount ra = new RelatedAccount();
            ra.accountId = rel.Secondary_Account__c;
            ra.name = rel.Secondary_Account__r.Name;
            ra.recordType = rel.Secondary_Account__r.RecordType != null
                ? rel.Secondary_Account__r.RecordType.DeveloperName : '';
            ra.relationshipTypes = rel.Relationship_Type__c;
            ctx.relatedAccounts.add(ra);
        }
        // Relationships where this account is Secondary (Primary = child/related)
        for (Relationship__c rel : [
            SELECT Primary_Account__c, Primary_Account__r.Name,
                   Primary_Account__r.RecordType.DeveloperName,
                   Relationship_Type__c
            FROM Relationship__c
            WHERE Secondary_Account__c = :accountId
        ]) {
            if (rel.Primary_Account__c == null || relatedIds.contains(rel.Primary_Account__c)) continue;
            RelatedAccount ra = new RelatedAccount();
            ra.accountId = rel.Primary_Account__c;
            ra.name = rel.Primary_Account__r.Name;
            ra.recordType = rel.Primary_Account__r.RecordType != null
                ? rel.Primary_Account__r.RecordType.DeveloperName : '';
            ra.relationshipTypes = rel.Relationship_Type__c;
            ctx.relatedAccounts.add(ra);
        }

        // ---- Nearby schools ----
        ctx.nearbySchools = findNearbySchoolsInternal(acct, accountId);

        // ---- Same-district schools ----
        ctx.districtSchools = findDistrictSchoolsInternal(acct, accountId);

        // ---- Full product catalog ----
        ctx.productCatalog = new List<ProductInfo>();
        for (Product2 p : [
            SELECT Id, Name, Family
            FROM Product2
            WHERE IsActive = true
            ORDER BY Name
        ]) {
            ProductInfo pi = new ProductInfo();
            pi.productId = p.Id;
            pi.name = p.Name;
            pi.family = p.Family;
            ctx.productCatalog.add(pi);
        }

        return ctx;
    }

    /**
     * @description Sends a chat message to OpenRouter with the full account context.
     * @param accountId The context Account.
     * @param userMessage The user's natural-language message.
     * @param conversationHistoryJson JSON array of prior {role, content} messages (optional).
     * @return The AI's text reply.
     */
    @AuraEnabled
    public static ChatResponse chat(Id accountId, String userMessage, String conversationHistoryJson) {
        if (String.isBlank(userMessage)) {
            throw new AuraHandledException('Please enter a message.');
        }

        AI_Configuration__mdt config = getActiveConfig();
        if (config == null || String.isBlank(config.API_Key__c)
            || config.API_Key__c == 'YOUR_OPENROUTER_API_KEY') {
            throw new AuraHandledException(
                'AI is not configured. Set your OpenRouter API key in Setup > Custom Metadata Types > AI Configuration.'
            );
        }

        // Geocode the current school first (HTTP callouts to Google Maps) so
        // exact coordinates are available for distance computation. This runs
        // BEFORE the OpenRouter callout and BEFORE any DML, so we avoid the
        // "uncommitted work pending" error.
        Map<Id, GeocodingService.GeocodeResult> geoResults =
            GeocodingService.geocodeForChat(new Set<Id>{ accountId });

        // Gather context (cacheable, no DML or callouts)
        AccountContext ctx = getAccountContext(accountId);
        String systemPrompt = buildSystemPrompt(config, ctx);

        // Build message payload
        List<Object> messages = new List<Object>();
        messages.add(new Map<String, String>{ 'role' => 'system', 'content' => systemPrompt });

        // Conversation history (JSON array of {role, content})
        if (String.isNotBlank(conversationHistoryJson)) {
            try {
                List<Object> history = (List<Object>) JSON.deserializeUntyped(conversationHistoryJson);
                for (Object h : history) {
                    Map<String, Object> m = (Map<String, Object>) h;
                    String role = String.valueOf(m.get('role'));
                    String content = String.valueOf(m.get('content'));
                    if (String.isNotBlank(role) && String.isNotBlank(content)) {
                        messages.add(new Map<String, String>{ 'role' => role, 'content' => content });
                    }
                }
            } catch (Exception e) {
                // Ignore malformed history — fall through to just the user message.
            }
        }
        messages.add(new Map<String, String>{ 'role' => 'user', 'content' => userMessage });

        // Call the model (HTTP callout to OpenRouter)
        ChatResponse resp = callOpenRouter(config, messages);

        // Persist geocoding results AFTER all callouts are done (DML only now).
        GeocodingService.persistGeocodeResults(geoResults);

        return resp;
    }

    /**
     * @description Enqueues an async geocoding job for the given account so its
     *              coordinates (and thus distances to other schools) get cached.
     *              Called by the LWC on load, in its own transaction, so it never
     *              conflicts with the chat() OpenRouter callout.
     * @param accountId The Account to geocode.
     */
    @AuraEnabled
    public static void ensureGeocoded(Id accountId) {
        if (accountId == null) {
            return;
        }
        GeocodingService.enqueueGeocoding(new Set<Id>{ accountId });
    }

    /**
     * @description Returns nearby schools that do NOT have the products this
     *              school independently purchased.
     */
    @AuraEnabled(cacheable=true)
    public static List<NearbySchool> findNearbySchools(Id accountId) {
        Account acct = [
            SELECT Id, BillingState, ParentId, Latitude__c, Longitude__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        return findNearbySchoolsInternal(acct, accountId);
    }

    /**
     * @description Creates a renewal opportunity for the given Assets.
     *              Delegates to AssetTimelineController for the actual
     *              creation logic (grouping, price book, line items).
     * @param accountId The context Account.
     * @param assetIds  The Assets to include in the renewal.
     * @return RenewalResult with the new Opportunity details.
     */
    @AuraEnabled
    public static RenewalResult createRenewalOpportunity(Id accountId, List<Id> assetIds) {
        RenewalResult result = new RenewalResult();
        result.success = false;

        if (accountId == null || assetIds == null || assetIds.isEmpty()) {
            result.message = 'I need at least one asset to create a renewal.';
            return result;
        }

        try {
            Id oppId = AssetTimelineController.createRenewalOpportunities(accountId, assetIds);
            result.opportunityId = oppId;

            Opportunity opp = [
                SELECT Id, Name, Amount, CloseDate
                FROM Opportunity
                WHERE Id = :oppId
                LIMIT 1
            ];
            result.opportunityName = opp.Name;
            result.success = true;
            result.message = 'Renewal opportunity "' + opp.Name + '" created successfully.';
        } catch (Exception e) {
            result.message = 'I could not create the renewal opportunity: ' + e.getMessage();
        }
        return result;
    }

    /* ================= INTERNAL HELPERS ================= */

    /**
     * Finds schools in the same state that are missing products this account
     * independently purchased (Purchased_By__c is null or equals the account).
     */
    private static List<NearbySchool> findNearbySchoolsInternal(Account acct, Id accountId) {
        List<NearbySchool> result = new List<NearbySchool>();
        if (acct == null || String.isBlank(acct.BillingState)) {
            return result;
        }

        // Products this account independently purchased
        Set<Id> ownProductIds = new Set<Id>();
        Map<Id, String> ownProductNames = new Map<Id, String>();
        for (Asset a : [
            SELECT Id, Product2Id, Product2.Name
            FROM Asset
            WHERE AccountId = :accountId
              AND Product2Id != null
        ]) {
            // "Independently purchased" = no Purchased_By__c (self) 
            ownProductIds.add(a.Product2Id);
            ownProductNames.put(a.Product2Id, a.Product2.Name);
        }
        if (ownProductIds.isEmpty()) {
            return result;
        }

        // All School accounts in the same state (excluding current account).
        // Same-district schools are filtered in Apex (SOQL != null is unreliable).
        Map<Id, Account> schoolMap = new Map<Id, Account>();
        for (Account school : [
            SELECT Id, Name, School_Type__c, Grades_Served__c,
                   Student_Population__c, Faculty_Size__c,
                   BillingCity, BillingState, ParentId,
                   Latitude__c, Longitude__c
            FROM Account
            WHERE RecordType.DeveloperName = 'School'
              AND BillingState = :acct.BillingState
              AND Id != :accountId
            ORDER BY Name
        ]) {
            // Skip schools in the same district as the current account
            if (acct.ParentId != null && school.ParentId == acct.ParentId) {
                continue;
            }
            schoolMap.put(school.Id, school);
        }
        if (schoolMap.isEmpty()) {
            return result;
        }

        // Assets for those schools, grouped by account
        Map<Id, Set<Id>> schoolProductIds = new Map<Id, Set<Id>>();
        for (Asset a : [
            SELECT AccountId, Product2Id
            FROM Asset
            WHERE AccountId IN :schoolMap.keySet()
              AND Product2Id != null
        ]) {
            if (!schoolProductIds.containsKey(a.AccountId)) {
                schoolProductIds.put(a.AccountId, new Set<Id>());
            }
            schoolProductIds.get(a.AccountId).add(a.Product2Id);
        }

        for (Id schoolId : schoolMap.keySet()) {
            Account s = schoolMap.get(schoolId);
            Set<Id> have = schoolProductIds.get(schoolId) != null
                ? schoolProductIds.get(schoolId) : new Set<Id>();

            // Missing products = own products this school does NOT have
            Set<Id> missing = new Set<Id>();
            for (Id prodId : ownProductIds) {
                if (!have.contains(prodId)) {
                    missing.add(prodId);
                }
            }
            if (missing.isEmpty()) {
                continue; // School already has everything — not a whitespace target
            }

            NearbySchool ns = new NearbySchool();
            ns.accountId = s.Id;
            ns.name = s.Name;
            ns.schoolType = s.School_Type__c;
            ns.gradesServed = s.Grades_Served__c;
            ns.studentPopulation = s.Student_Population__c != null
                ? s.Student_Population__c.intValue() : null;
            ns.facultySize = s.Faculty_Size__c != null
                ? s.Faculty_Size__c.intValue() : null;
            ns.city = s.BillingCity;
            ns.state = s.BillingState;
            ns.distanceMiles = distanceMilesBetween(acct, s);

            ns.existingProducts = new List<String>();
            for (Id pid : have) {
                ns.existingProducts.add(productNameFor(pid));
            }

            ns.missingProducts = new List<String>();
            for (Id pid : missing) {
                ns.missingProducts.add(ownProductNames.get(pid));
            }
            ns.missingProducts.sort();

            result.add(ns);
        }
        return result;
    }

    /**
     * Finds the other schools that belong to the same district (same ParentId)
     * as the current account and lists the products each one has. This lets the
     * AI cross-reference products across schools within a district.
     */
    private static List<DistrictSchool> findDistrictSchoolsInternal(Account acct, Id accountId) {
        List<DistrictSchool> result = new List<DistrictSchool>();
        if (acct == null || acct.ParentId == null) {
            return result;
        }

        // All School accounts under the same district, excluding the current one.
        Map<Id, Account> districtSchoolMap = new Map<Id, Account>();
        for (Account school : [
            SELECT Id, Name, School_Type__c, Grades_Served__c,
                   Student_Population__c, Faculty_Size__c,
                   BillingCity, BillingState,
                   Latitude__c, Longitude__c
            FROM Account
            WHERE RecordType.DeveloperName = 'School'
              AND ParentId = :acct.ParentId
              AND Id != :accountId
            ORDER BY Name
        ]) {
            districtSchoolMap.put(school.Id, school);
        }
        if (districtSchoolMap.isEmpty()) {
            return result;
        }

        // Products those schools own, grouped by account.
        Map<Id, Set<Id>> districtSchoolProductIds = new Map<Id, Set<Id>>();
        // Products each school purchased for itself (Purchased_By__c = the school).
        Map<Id, Set<Id>> districtSchoolSelfPurchasedIds = new Map<Id, Set<Id>>();
        for (Asset a : [
            SELECT AccountId, Product2Id, Purchased_By__c
            FROM Asset
            WHERE AccountId IN :districtSchoolMap.keySet()
              AND Product2Id != null
        ]) {
            if (!districtSchoolProductIds.containsKey(a.AccountId)) {
                districtSchoolProductIds.put(a.AccountId, new Set<Id>());
            }
            districtSchoolProductIds.get(a.AccountId).add(a.Product2Id);

            // "Individually purchased" = the school itself is the purchaser.
            if (a.Purchased_By__c == a.AccountId) {
                if (!districtSchoolSelfPurchasedIds.containsKey(a.AccountId)) {
                    districtSchoolSelfPurchasedIds.put(a.AccountId, new Set<Id>());
                }
                districtSchoolSelfPurchasedIds.get(a.AccountId).add(a.Product2Id);
            }
        }

        for (Id schoolId : districtSchoolMap.keySet()) {
            Account s = districtSchoolMap.get(schoolId);
            DistrictSchool ds = new DistrictSchool();
            ds.accountId = s.Id;
            ds.name = s.Name;
            ds.schoolType = s.School_Type__c;
            ds.gradesServed = s.Grades_Served__c;
            ds.studentPopulation = s.Student_Population__c != null
                ? s.Student_Population__c.intValue() : null;
            ds.facultySize = s.Faculty_Size__c != null
                ? s.Faculty_Size__c.intValue() : null;
            ds.city = s.BillingCity;
            ds.state = s.BillingState;
            ds.distanceMiles = distanceMilesBetween(acct, s);

            ds.products = new List<String>();
            Set<Id> have = districtSchoolProductIds.get(schoolId) != null
                ? districtSchoolProductIds.get(schoolId) : new Set<Id>();
            for (Id pid : have) {
                ds.products.add(productNameFor(pid));
            }
            ds.products.sort();

            ds.individuallyPurchasedProducts = new List<String>();
            Set<Id> selfPurchased = districtSchoolSelfPurchasedIds.get(schoolId) != null
                ? districtSchoolSelfPurchasedIds.get(schoolId) : new Set<Id>();
            for (Id pid : selfPurchased) {
                ds.individuallyPurchasedProducts.add(productNameFor(pid));
            }
            ds.individuallyPurchasedProducts.sort();

            result.add(ds);
        }
        return result;
    }

    /**
     * @description Computes the great-circle distance in miles between two
     *              accounts using the Haversine formula. Returns null if either
     *              account lacks coordinates.
     */
    private static Double distanceMilesBetween(Account a, Account b) {
        if (a == null || b == null
            || a.Latitude__c == null || a.Longitude__c == null
            || b.Latitude__c == null || b.Longitude__c == null) {
            return null;
        }

        Double lat1 = a.Latitude__c.doubleValue();
        Double lon1 = a.Longitude__c.doubleValue();
        Double lat2 = b.Latitude__c.doubleValue();
        Double lon2 = b.Longitude__c.doubleValue();

        Double earthRadiusMiles = 3958.8;
        Double dLat = toRadians(lat2 - lat1);
        Double dLon = toRadians(lon2 - lon1);
        Double rLat1 = toRadians(lat1);
        Double rLat2 = toRadians(lat2);

        Double aVal = Math.sin(dLat / 2) * Math.sin(dLat / 2)
            + Math.cos(rLat1) * Math.cos(rLat2)
            * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        Double c = 2 * Math.atan2(Math.sqrt(aVal), Math.sqrt(1 - aVal));

        return earthRadiusMiles * c;
    }

    /** Converts degrees to radians (Apex has no Math.toRadians). */
    private static Double toRadians(Double degrees) {
        return degrees * Math.PI / 180;
    }

    /** Cached product name lookup helper. */
    private static Map<Id, String> productNameCache = new Map<Id, String>();
    private static String productNameFor(Id pid) {
        if (!productNameCache.containsKey(pid)) {
            productNameCache.put(pid, '');
            for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Id = :pid LIMIT 1]) {
                productNameCache.put(p.Id, p.Name);
            }
        }
        return productNameCache.get(pid);
    }

    /** Maps an Asset to the lightweight wrapper. */
    private static AssetInfo mapAsset(Asset a, Id selfAccountId, String selfAccountName) {
        AssetInfo ai = new AssetInfo();
        ai.assetId = a.Id;
        ai.name = a.Name;
        ai.productName = a.Product2Id != null ? a.Product2.Name : '';
        ai.productFamily = a.Product2Id != null ? a.Product2.Family : '';
        ai.status = a.Status;
        ai.expirationDate = a.UsageEndDate;
        ai.price = a.Price;
        // Purchased by: use the related account name, or the account itself if self-purchased
        if (a.Purchased_By__r != null) {
            ai.purchasedBy = a.Purchased_By__r.Name;
        } else if (a.Purchased_By__c == null) {
            ai.purchasedBy = selfAccountName; // Self-purchased
        } else {
            ai.purchasedBy = '';
        }
        ai.isSelfPurchased = a.Purchased_By__c == null || a.Purchased_By__c == selfAccountId;
        ai.renewalOpportunityId = a.Renewal_Opportunity__c;
        return ai;
    }

    /** Test-only override so tests can inject a config without DML (MDT is not DML-able). */
    @TestVisible
    private static AI_Configuration__mdt testConfigOverride;

    /** Retrieves the active AI_Configuration__mdt record. */
    private static AI_Configuration__mdt getActiveConfig() {
        if (testConfigOverride != null) {
            return testConfigOverride;
        }
        List<AI_Configuration__mdt> configs = [
            SELECT Id, API_Key__c, Model__c, Endpoint__c, Max_Tokens__c,
                   Temperature__c, System_Prompt__c, Is_Active__c
            FROM AI_Configuration__mdt
            WHERE Is_Active__c = true
            LIMIT 1
        ];
        return configs.isEmpty() ? null : configs[0];
    }

    /**
     * Builds the system prompt with the account context rendered as readable
     * prose (not JSON) plus a strong conversational persona. Models converse
     * far better over natural-language context than over raw data dumps.
     */
    private static String buildSystemPrompt(AI_Configuration__mdt config, AccountContext ctx) {
        String base = config.System_Prompt__c;
        if (String.isBlank(base)) {
            base = 'You are Raptor AI, an inside sales assistant for a school-safety technology company.';
        }
        String contextText = renderContextAsProse(ctx);

        // Always tell the AI what "today" is so it can reason about renewal
        // timing, expiration windows, and urgency correctly.
        String todayLine = 'Current date: ' + Date.today().format() + '\n';
        contextText = todayLine + contextText;

        // Capabilities the AI can invoke. The LWC parses the special
        // [CREATE_RENEWAL:...] marker and performs the actual DML.
        String capabilities =
            '\n\n=== YOUR CAPABILITIES ===\n' +
            'IMPORTANT: Never guess or estimate distances. If a distance is shown above (e.g. "5.2 miles away"), use that exact number. ' +
            'If no distance is shown, say "I do not have the exact mileage" rather than guessing.\n' +
            'You can create renewal opportunities for this account when the user asks you to.\n' +
            'When the user asks you to create a renewal (e.g. "create a renewal", "set up the renewal", ' +
            '"start the renewal process", "renew these assets"), you should:\n' +
            '1. Identify which assets need renewal. Prefer assets that are expiring soonest and do NOT ' +
            'already have a renewal opportunity (the context marks those with "renewal opportunity already exists").\n' +
            '2. If the user named specific assets or products, use those. If they said "all" or "everything", ' +
            'include all assets that do not already have a renewal opportunity.\n' +
            '3. Respond conversationally confirming what you are about to do, then append the marker ' +
            '[CREATE_RENEWAL:assetId1,assetId2,...] using the exact asset IDs from the context above.\n' +
            '4. Do NOT invent asset IDs. Only use the asset IDs listed in the account facts.\n' +
            '5. If no assets qualify (all already have renewals, or none exist), explain that conversationally ' +
            'and do NOT include the marker.\n' +
            '6. After the marker is processed, the system will tell you the result. Acknowledge it naturally.\n' +
            'Example: "I will create a renewal for your Raptor Sales Solution and Raptor Analytics. ' +
            '[CREATE_RENEWAL:02gXXXXXXXXXXXXXXX,02gYYYYYYYYYYYYYYY]"';

        return base + '\n\n=== ACCOUNT FACTS (for your reference only) ===\n' + contextText + capabilities;
    }

    /**
     * Renders the account context as clean, readable prose so the model can
     * converse naturally instead of echoing a JSON structure back.
     */
    private static String renderContextAsProse(AccountContext ctx) {
        String s = '';

        // ---- Account profile ----
        s += 'Account: ' + nvl(ctx.accountName, 'Unknown');
        if (String.isNotBlank(ctx.schoolType)) {
            s += ' (' + ctx.schoolType + ')';
        }
        s += '\n';
        if (String.isNotBlank(ctx.gradesServed)) {
            s += 'Grades served: ' + ctx.gradesServed + '\n';
        }
        if (ctx.studentPopulation != null) {
            s += 'Student population: ' + ctx.studentPopulation + '\n';
        }
        if (ctx.facultySize != null) {
            s += 'Faculty size: ' + ctx.facultySize + '\n';
        }
        if (String.isNotBlank(ctx.billingCity) || String.isNotBlank(ctx.billingState)) {
            s += 'Location: ' + nvl(ctx.billingCity, '') + ', ' + nvl(ctx.billingState, '') + '\n';
        }
        if (String.isNotBlank(ctx.parentName)) {
            s += 'Parent district: ' + ctx.parentName + '\n';
        }

        // ---- Assets ----
        s += '\nAssets owned by this account:\n';
        if (ctx.assets == null || ctx.assets.isEmpty()) {
            s += '- None\n';
        } else {
            for (AssetInfo a : ctx.assets) {
                s += '- ' + nvl(a.productName, a.name);
                s += ' (Asset ID: ' + a.assetId + ')';
                if (String.isNotBlank(a.productFamily)) {
                    s += ' (' + a.productFamily + ')';
                }
                if (String.isNotBlank(a.status)) {
                    s += ' — ' + a.status;
                }
                if (a.expirationDate != null) {
                    s += ', expires ' + a.expirationDate.format();
                }
                // Always show who purchased the asset so the AI can answer
                // "who bought this?" questions confidently.
                if (a.isSelfPurchased != null && a.isSelfPurchased) {
                    s += ', purchased by ' + nvl(a.purchasedBy, ctx.accountName) + ' (self)';
                } else if (String.isNotBlank(a.purchasedBy)) {
                    s += ', purchased by ' + a.purchasedBy;
                } else {
                    s += ', purchaser unknown';
                }
                if (a.renewalOpportunityId != null) {
                    s += ', renewal opportunity already exists';
                }
                s += '\n';
            }
        }

        // ---- Related accounts ----
        if (ctx.relatedAccounts != null && !ctx.relatedAccounts.isEmpty()) {
            s += '\nRelated accounts:\n';
            for (RelatedAccount ra : ctx.relatedAccounts) {
                s += '- ' + nvl(ra.name, 'Unknown');
                if (String.isNotBlank(ra.recordType)) {
                    s += ' (' + ra.recordType + ')';
                }
                if (String.isNotBlank(ra.relationshipTypes)) {
                    s += ' — ' + ra.relationshipTypes;
                }
                s += '\n';
            }
        }

        // ---- Other schools in the same district ----
        if (ctx.districtSchools != null && !ctx.districtSchools.isEmpty()) {
            s += '\nOther schools in the same district (' + nvl(ctx.parentName, 'this district') + '):\n';
            for (DistrictSchool ds : ctx.districtSchools) {
                s += '- ' + nvl(ds.name, 'Unknown');
                if (String.isNotBlank(ds.schoolType)) {
                    s += ' (' + ds.schoolType + ')';
                }
                if (String.isNotBlank(ds.gradesServed)) {
                    s += ', grades ' + ds.gradesServed;
                }
                if (ds.studentPopulation != null) {
                    s += ', ' + ds.studentPopulation + ' students';
                }
                if (String.isNotBlank(ds.city) || String.isNotBlank(ds.state)) {
                    s += ', ' + nvl(ds.city, '') + ' ' + nvl(ds.state, '');
                }
                if (ds.distanceMiles != null) {
                    s += ', ' + formatDistance(ds.distanceMiles) + ' away';
                }
                if (ds.products != null && !ds.products.isEmpty()) {
                    s += ' — products: ' + String.join(ds.products, ', ');
                } else {
                    s += ' — products: none';
                }
                if (ds.individuallyPurchasedProducts != null && !ds.individuallyPurchasedProducts.isEmpty()) {
                    s += ' — individually purchased: ' + String.join(ds.individuallyPurchasedProducts, ', ');
                }
                s += '\n';
            }
        }

        // ---- Nearby schools (capped for focus) ----
        if (ctx.nearbySchools != null && !ctx.nearbySchools.isEmpty()) {
            s += '\nNearby schools (potential whitespace targets):\n';
            Integer shown = 0;
            for (NearbySchool ns : ctx.nearbySchools) {
                if (shown >= 25) {
                    s += '- ... and ' + (ctx.nearbySchools.size() - shown) + ' more\n';
                    break;
                }
                s += '- ' + nvl(ns.name, 'Unknown');
                if (String.isNotBlank(ns.schoolType)) {
                    s += ' (' + ns.schoolType + ')';
                }
                if (ns.studentPopulation != null) {
                    s += ', ' + ns.studentPopulation + ' students';
                }
                if (String.isNotBlank(ns.city) || String.isNotBlank(ns.state)) {
                    s += ', ' + nvl(ns.city, '') + ' ' + nvl(ns.state, '');
                }
                if (ns.distanceMiles != null) {
                    s += ', ' + formatDistance(ns.distanceMiles) + ' away';
                }
                if (ns.missingProducts != null && !ns.missingProducts.isEmpty()) {
                    s += ' — missing: ' + String.join(ns.missingProducts, ', ');
                }
                s += '\n';
                shown++;
            }
        }

        // ---- Product catalog ----
        if (ctx.productCatalog != null && !ctx.productCatalog.isEmpty()) {
            s += '\nFull product catalog:\n';
            for (ProductInfo p : ctx.productCatalog) {
                s += '- ' + nvl(p.name, 'Unknown');
                if (String.isNotBlank(p.family)) {
                    s += ' (' + p.family + ')';
                }
                s += '\n';
            }
        }

        return s;
    }

    /** Null-safe string helper. */
    private static String nvl(String val, String fallback) {
        return String.isNotBlank(val) ? val : fallback;
    }

    /** Formats a distance in miles for the prompt (1 decimal place). */
    private static String formatDistance(Double miles) {
        if (miles == null) {
            return '';
        }
        Long rounded = Math.round(miles * 10);
        Double oneDecimal = rounded / 10.0;
        return String.valueOf(oneDecimal) + ' miles';
    }

    /**
     * Calls the OpenRouter chat completions endpoint.
     */
    private static ChatResponse callOpenRouter(AI_Configuration__mdt config, List<Object> messages) {
        // Trim config values to guard against invisible whitespace pasted into metadata.
        String endpoint = String.isNotBlank(config.Endpoint__c)
            ? config.Endpoint__c.trim()
            : 'https://openrouter.ai/api/v1/chat/completions';
        String model = String.isNotBlank(config.Model__c)
            ? config.Model__c.trim()
            : 'anthropic/claude-3.5-sonnet';
        Integer maxTokens = config.Max_Tokens__c != null ? config.Max_Tokens__c.intValue() : 1024;
        Decimal temp = config.Temperature__c != null ? config.Temperature__c : 0.7;

        Map<String, Object> reqBody = new Map<String, Object>();
        reqBody.put('model', model);
        reqBody.put('messages', messages);
        reqBody.put('max_tokens', maxTokens);
        reqBody.put('temperature', temp);

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + config.API_Key__c);
        req.setHeader('HTTP-Referer', 'https://github.com/');
        req.setHeader('X-Title', 'Raptor Inside Sales AI');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(reqBody));

        Http http = new Http();
        HttpResponse res = http.send(req);

        ChatResponse resp = new ChatResponse();
        resp.rawJson = res.getBody();

        if (res.getStatusCode() != 200) {
            String msg = 'AI request failed (' + res.getStatusCode() + '): ';
            try {
                Map<String, Object> errBody = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                if (errBody.containsKey('error')) {
                    Object err = errBody.get('error');
                    if (err instanceof Map<String, Object>) {
                        Map<String, Object> errMap = (Map<String, Object>) err;
                        if (errMap.containsKey('message')) {
                            msg += String.valueOf(errMap.get('message'));
                        }
                    }
                }
            } catch (Exception e) {
                msg += res.getBody() != null ? res.getBody() : 'Unknown error';
            }
            throw new AuraHandledException(msg);
        }

        // Parse the content from the response
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> choices = (List<Object>) body.get('choices');
        if (choices != null && !choices.isEmpty()) {
            Map<String, Object> choice = (Map<String, Object>) choices[0];
            Map<String, Object> message = (Map<String, Object>) choice.get('message');
            if (message != null && message.containsKey('content')) {
                resp.reply = String.valueOf(message.get('content'));
            }
        }
        if (String.isBlank(resp.reply)) {
            resp.reply = 'The AI returned an empty response.';
        }
        return resp;
    }
}