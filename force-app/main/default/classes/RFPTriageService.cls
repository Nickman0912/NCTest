/**
 * REST endpoint for the RFP triage pipeline.
 * The Cloud Run service POSTs extracted RFP characteristics here after
 * analyzing the source document. Auth is handled via the connected
 * app's OAuth access token (standard Salesforce REST auth).
 */
@RestResource(urlMapping='/rfp/triage')
global with sharing class RFPTriageService {

    global class TriageRequest {
        public String rfpName;
        public String issuingOrganization;
        public String dueDate;             // ISO yyyy-MM-dd
        public Decimal estimatedValue;
        public String geography;
        public String requiredCapabilities;
        public String incumbentVendor;
        public String decisionTimeline;
        public Decimal pursuitScore;
        public Decimal extractionConfidence; // 0-100 reliability of extraction
        public String extractionMethod;      // Text | Vision
        public String recommendation;      // Pursue | Review | Decline
        public String recommendationNotes;
        public String sourceEmail;
        public String portalUrl;           // contractor portal / doc download link
        public String documentBase64;      // original RFP file, optional
        public String documentFileName;    // e.g. "city-rfp-2026.pdf"
    }

    global class TriageResponse {
        public String rfpId;
        public String status;
        public String errorMessage;
    }

    @HttpPost
    global static TriageResponse createTriageRecord() {
        TriageResponse resp = new TriageResponse();
        RestRequest req = RestContext.request;

        try {
            TriageRequest triage = (TriageRequest) JSON.deserialize(
                req.requestBody.toString(), TriageRequest.class);

            RFP__c rfp = new RFP__c(
                Name = String.isNotBlank(triage.rfpName)
                    ? triage.rfpName.left(80)
                    : 'RFP - ' + Datetime.now().format('yyyy-MM-dd HH:mm'),
                Issuing_Organization__c = triage.issuingOrganization,
                Estimated_Value__c = triage.estimatedValue,
                Geography__c = triage.geography,
                Required_Capabilities__c = triage.requiredCapabilities,
                Incumbent_Vendor__c = triage.incumbentVendor,
                Decision_Timeline__c = triage.decisionTimeline,
                Pursuit_Score__c = triage.pursuitScore,
                Extraction_Confidence__c = triage.extractionConfidence,
                Extraction_Method__c = triage.extractionMethod,
                Recommendation__c = triage.recommendation,
                Recommendation_Notes__c = triage.recommendationNotes,
                Source_Email__c = triage.sourceEmail,
                Portal_URL__c = triage.portalUrl,
                Status__c = 'Triaged'
            );

            if (String.isNotBlank(triage.dueDate)) {
                rfp.Due_Date__c = Date.valueOf(triage.dueDate);
            }

            insert rfp;

            // Attach the original RFP document, if provided
            if (String.isNotBlank(triage.documentBase64)
                    && String.isNotBlank(triage.documentFileName)) {
                ContentVersion cv = new ContentVersion(
                    Title = triage.documentFileName,
                    PathOnClient = triage.documentFileName,
                    VersionData = EncodingUtil.base64Decode(triage.documentBase64)
                );
                insert cv;

                Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion
                                   WHERE Id = :cv.Id].ContentDocumentId;
                insert new ContentDocumentLink(
                    ContentDocumentId = contentDocId,
                    LinkedEntityId = rfp.Id,
                    ShareType = 'V'
                );
            }

            resp.rfpId = rfp.Id;
            resp.status = 'success';
        } catch (Exception e) {
            resp.status = 'error';
            resp.errorMessage = e.getMessage();
            RestContext.response.statusCode = 400;
        }
        return resp;
    }
}
