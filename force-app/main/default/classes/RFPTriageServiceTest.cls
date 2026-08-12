@IsTest
private class RFPTriageServiceTest {

    @IsTest
    static void createsRfpWithDocument() {
        String body = JSON.serialize(new Map<String, Object>{
            'rfpName' => 'City of Springfield Fire Apparatus RFP',
            'issuingOrganization' => 'City of Springfield',
            'dueDate' => '2026-09-15',
            'estimatedValue' => 250000,
            'geography' => 'Illinois',
            'requiredCapabilities' => 'Aerial apparatus, pumpers',
            'incumbentVendor' => 'Pierce',
            'decisionTimeline' => 'Q4 2026',
            'pursuitScore' => 78,
            'recommendation' => 'Pursue',
            'recommendationNotes' => 'Strong capability match, value above threshold.',
            'sourceEmail' => 'rfps@client.com',
            'portalUrl' => 'https://bc.example.com/bid/123',
            'documentBase64' => EncodingUtil.base64Encode(Blob.valueOf('fake pdf')),
            'documentFileName' => 'springfield-rfp.pdf'
        });

        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/rfp/triage';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        RFPTriageService.TriageResponse resp = RFPTriageService.createTriageRecord();

        System.assertEquals('success', resp.status);
        RFP__c rfp = [SELECT Due_Date__c, Pursuit_Score__c, Status__c, Portal_URL__c
                      FROM RFP__c WHERE Id = :resp.rfpId];
        System.assertEquals(Date.newInstance(2026, 9, 15), rfp.Due_Date__c);
        System.assertEquals(78, rfp.Pursuit_Score__c);
        System.assertEquals('Triaged', rfp.Status__c);
        System.assertEquals('https://bc.example.com/bid/123', rfp.Portal_URL__c);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink
                                WHERE LinkedEntityId = :rfp.Id]);
    }

    @IsTest
    static void handlesBadPayload() {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/rfp/triage';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"dueDate": "not-a-date"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        RFPTriageService.TriageResponse resp = RFPTriageService.createTriageRecord();

        System.assertEquals('error', resp.status);
        System.assertNotEquals(null, resp.errorMessage);
    }
}
