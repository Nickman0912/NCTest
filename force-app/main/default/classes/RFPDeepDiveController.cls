/**
 * @description Apex controller for the RFP Deep Dive LWC.
 *              Proxies estimator questions to the Cloud Run RAG endpoint,
 *              which retrieves relevant document chunks from pgvector and
 *              answers with citations. The webhook secret stays server-side
 *              in the RFP_Triage_Config__mdt record - never in the browser.
 */
public with sharing class RFPDeepDiveController {

    /** Answer returned to the LWC. */
    public class AskResponse {
        @AuraEnabled public String answer;
        @AuraEnabled public List<Citation> citations;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
    }

    public class Citation {
        @AuraEnabled public String file;
        @AuraEnabled public Integer chunk;
        @AuraEnabled public String excerpt;
    }

    /** Signed-URL upload session returned to the LWC. */
    public class UploadUrlResponse {
        @AuraEnabled public String uploadUrl;
        @AuraEnabled public String gcsPath;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
    }

    /** Result of an ingest call. */
    public class IngestResponse {
        @AuraEnabled public String status;
        @AuraEnabled public Integer chunks;
        @AuraEnabled public String reason;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
    }

    /** Project summary returned to the LWC. */
    public class SummaryResponse {
        @AuraEnabled public String summary;
        @AuraEnabled public List<Citation> citations;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
    }

    /** Config status so the LWC can show a setup warning if needed. */
    @AuraEnabled(cacheable=true)
    public static Boolean isConfigured() {
        RFP_Triage_Config__mdt cfg = getConfig();
        return cfg != null
            && String.isNotBlank(cfg.Endpoint__c)
            && String.isNotBlank(cfg.Webhook_Secret__c);
    }

    /**
     * @description Ask a question about an RFP's ingested documents.
     * @param rfpId   The RFP__c record Id (used as the vector DB partition key).
     * @param question Natural-language question from the estimator.
     */
    @AuraEnabled
    public static AskResponse ask(Id rfpId, String question) {
        AskResponse resp = new AskResponse();
        resp.success = false;

        if (rfpId == null || String.isBlank(question)) {
            resp.errorMessage = 'A record Id and question are required.';
            return resp;
        }

        RFP_Triage_Config__mdt cfg = getConfig();
        if (cfg == null || String.isBlank(cfg.Endpoint__c)
                || String.isBlank(cfg.Webhook_Secret__c)) {
            resp.errorMessage = 'RFP Triage is not configured. '
                + 'Populate the RFP Triage Config custom metadata record.';
            return resp;
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(cfg.Endpoint__c.removeEnd('/') + '/ask');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-Webhook-Secret', cfg.Webhook_Secret__c);
        req.setTimeout(60000); // RAG round-trip: embed + retrieve + generate
        req.setBody(JSON.serialize(new Map<String, String>{
            'rfpId'    => String.valueOf(rfpId),
            'question' => question
        }));

        try {
            HttpResponse httpResp = new Http().send(req);
            if (httpResp.getStatusCode() == 200) {
                Map<String, Object> body =
                    (Map<String, Object>) JSON.deserializeUntyped(httpResp.getBody());
                resp.answer = (String) body.get('answer');
                resp.citations = new List<Citation>();
                for (Object c : (List<Object>) body.get('citations')) {
                    Map<String, Object> cm = (Map<String, Object>) c;
                    Citation cit = new Citation();
                    cit.file = (String) cm.get('file');
                    cit.chunk = cm.get('chunk') == null
                        ? null : Integer.valueOf(String.valueOf(cm.get('chunk')));
                    cit.excerpt = (String) cm.get('excerpt');
                    resp.citations.add(cit);
                }
                resp.success = true;
            } else {
                resp.errorMessage = 'Triage service returned '
                    + httpResp.getStatusCode() + ': ' + httpResp.getBody().abbreviate(200);
            }
        } catch (Exception e) {
            resp.errorMessage = 'Callout failed: ' + e.getMessage();
        }
        return resp;
    }

    /**
     * @description Get a V4 signed GCS upload URL so the LWC can push a large
     *              document direct-to-GCS (bypassing the 6MB Apex callout limit).
     */
    @AuraEnabled
    public static UploadUrlResponse getUploadUrl(Id rfpId, String filename,
                                                 String contentType) {
        UploadUrlResponse resp = new UploadUrlResponse();
        resp.success = false;
        if (rfpId == null || String.isBlank(filename)) {
            resp.errorMessage = 'A record Id and filename are required.';
            return resp;
        }
        try {
            Map<String, Object> body = postToService('/upload-url',
                new Map<String, String>{
                    'rfpId' => String.valueOf(rfpId),
                    'filename' => filename,
                    'contentType' => String.isBlank(contentType)
                        ? 'application/octet-stream' : contentType
                });
            resp.uploadUrl = (String) body.get('uploadUrl');
            resp.gcsPath = (String) body.get('gcsPath');
            resp.success = String.isNotBlank(resp.uploadUrl);
            if (!resp.success) resp.errorMessage = 'No upload URL returned.';
        } catch (Exception e) {
            resp.errorMessage = e.getMessage();
        }
        return resp;
    }

    /**
     * @description After the LWC uploads a file direct-to-GCS, tell the service
     *              to read it back and ingest it into the vector DB for RAG.
     */
    @AuraEnabled
    public static IngestResponse ingestDocument(Id rfpId, String filename,
                                                String gcsPath) {
        IngestResponse resp = new IngestResponse();
        resp.success = false;
        if (rfpId == null || String.isBlank(filename) || String.isBlank(gcsPath)) {
            resp.errorMessage = 'A record Id, filename and gcsPath are required.';
            return resp;
        }
        try {
            Map<String, Object> body = postToService('/ingest',
                new Map<String, String>{
                    'rfpId' => String.valueOf(rfpId),
                    'filename' => filename,
                    'gcsPath' => gcsPath
                });
            resp.status = (String) body.get('status');
            resp.reason = (String) body.get('reason');
            Object chunks = body.get('chunks');
            resp.chunks = chunks == null ? null : Integer.valueOf(String.valueOf(chunks));
            resp.success = resp.status == 'ingested';
        } catch (Exception e) {
            resp.errorMessage = e.getMessage();
        }
        return resp;
    }

    /**
     * @description Generate a project summary + recommendation from the RFP's
     *              ingested documents.
     */
    @AuraEnabled
    public static SummaryResponse summarize(Id rfpId) {
        SummaryResponse resp = new SummaryResponse();
        resp.success = false;
        if (rfpId == null) {
            resp.errorMessage = 'A record Id is required.';
            return resp;
        }
        try {
            Map<String, Object> body = postToService('/summarize',
                new Map<String, String>{ 'rfpId' => String.valueOf(rfpId) });
            resp.summary = (String) body.get('summary');
            resp.citations = parseCitations(body.get('citations'));
            resp.success = true;
        } catch (Exception e) {
            resp.errorMessage = e.getMessage();
        }
        return resp;
    }

    /**
     * @description Shared POST helper: serializes a JSON body to the given
     *              Cloud Run path with the webhook secret, and returns the
     *              parsed response map. Throws on non-200 so callers can catch.
     */
    private static Map<String, Object> postToService(String path,
                                                     Map<String, String> payload) {
        RFP_Triage_Config__mdt cfg = getConfig();
        if (cfg == null || String.isBlank(cfg.Endpoint__c)
                || String.isBlank(cfg.Webhook_Secret__c)) {
            throw new CalloutException('RFP Triage is not configured. '
                + 'Populate the RFP Triage Config custom metadata record.');
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(cfg.Endpoint__c.removeEnd('/') + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-Webhook-Secret', cfg.Webhook_Secret__c);
        req.setTimeout(60000);
        req.setBody(JSON.serialize(payload));

        HttpResponse httpResp = new Http().send(req);
        if (httpResp.getStatusCode() != 200) {
            throw new CalloutException('Triage service returned '
                + httpResp.getStatusCode() + ': '
                + httpResp.getBody().abbreviate(200));
        }
        return (Map<String, Object>) JSON.deserializeUntyped(httpResp.getBody());
    }

    /** Parse a raw citations list into typed Citation objects. */
    private static List<Citation> parseCitations(Object raw) {
        List<Citation> out = new List<Citation>();
        if (raw == null) return out;
        for (Object c : (List<Object>) raw) {
            Map<String, Object> cm = (Map<String, Object>) c;
            Citation cit = new Citation();
            cit.file = (String) cm.get('file');
            cit.chunk = cm.get('chunk') == null
                ? null : Integer.valueOf(String.valueOf(cm.get('chunk')));
            cit.excerpt = (String) cm.get('excerpt');
            out.add(cit);
        }
        return out;
    }

    /** Reads the singleton config record. */
    private static RFP_Triage_Config__mdt getConfig() {
        List<RFP_Triage_Config__mdt> cfgs = [
            SELECT Endpoint__c, Webhook_Secret__c
            FROM RFP_Triage_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        return cfgs.isEmpty() ? null : cfgs[0];
    }
}
