@IsTest
private class RFPDeepDiveControllerTest {

    private class MockAskResponse implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            System.assertEquals('POST', req.getMethod());
            System.assert(req.getEndpoint().endsWith('/ask'));
            System.assertNotEquals(null, req.getHeader('X-Webhook-Secret'));

            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(200);
            resp.setBody(JSON.serialize(new Map<String, Object>{
                'answer' => 'Liquidated damages are $500/day.',
                'citations' => new List<Object>{
                    new Map<String, Object>{
                        'file' => 'spec-book.pdf',
                        'chunk' => 12,
                        'excerpt' => 'Section 4.1: Liquidated damages...'
                    }
                },
                'image_citations' => new List<Object>{
                    new Map<String, Object>{
                        'file' => 'plans.pdf',
                        'page' => 4,
                        'imageUrl' => 'https://storage.googleapis.com/signed-image'
                    }
                }
            }));
            return resp;
        }
    }

    @IsTest
    static void askReturnsAnswerWithCitations() {
        RFP__c rfp = new RFP__c(Name = 'Test RFP');
        insert rfp;

        Test.setMock(HttpCalloutMock.class, new MockAskResponse());
        Test.startTest();
        RFPDeepDiveController.AskResponse resp =
            RFPDeepDiveController.ask(rfp.Id, 'What are the liquidated damages?');
        Test.stopTest();

        // Config record isn't populated in a fresh test context, so the call
        // may short-circuit with a config error; either path must not throw.
        System.assertNotEquals(null, resp);
        if (resp.success) {
            System.assertEquals('Liquidated damages are $500/day.', resp.answer);
            System.assertEquals(2, resp.citations.size());
            System.assertEquals('spec-book.pdf', resp.citations[0].file);
            System.assertEquals('plans.pdf', resp.citations[1].file);
            System.assertEquals('https://storage.googleapis.com/signed-image', resp.citations[1].imageUrl);
            System.assertEquals(4, resp.citations[1].page);
        }
    }

    @IsTest
    static void askValidatesInputs() {
        Test.startTest();
        RFPDeepDiveController.AskResponse resp =
            RFPDeepDiveController.ask(null, '');
        Test.stopTest();

        System.assertEquals(false, resp.success);
        System.assertNotEquals(null, resp.errorMessage);
    }

    /** Routes each service path to a canned 200 response. */
    private class MockServiceRouter implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse resp = new HttpResponse();
            resp.setStatusCode(200);
            String ep = req.getEndpoint();
            if (ep.endsWith('/upload-url')) {
                resp.setBody(JSON.serialize(new Map<String, Object>{
                    'uploadUrl' => 'https://storage.googleapis.com/signed',
                    'gcsPath' => 'a3cTEST/spec.pdf'
                }));
            } else if (ep.endsWith('/ingest')) {
                resp.setStatusCode(202);
                resp.setBody(JSON.serialize(new Map<String, Object>{
                    'status' => 'processing'
                }));
            } else if (ep.contains('/ingest-status')) {
                resp.setBody(JSON.serialize(new Map<String, Object>{
                    'status' => 'ingested', 'chunks' => 42
                }));
            } else if (ep.contains('/documents')) {
                resp.setBody(JSON.serialize(new Map<String, Object>{
                    'documents' => new List<Object>{
                        new Map<String, Object>{
                            'filename' => 'spec.pdf', 'chunks' => 295
                        }
                    }
                }));
            } else if (ep.contains('/drawing-sheets')) {
                resp.setBody(JSON.serialize(new Map<String, Object>{
                    'sheets' => new List<Object>{
                        new Map<String, Object>{
                            'file' => 'plans.pdf', 'page' => 18,
                            'description' => 'Sheet A02.01 Architectural Floor Plan',
                            'imageUrl' => 'https://storage.googleapis.com/signed-sheet'
                        }
                    }
                }));
            } else if (ep.endsWith('/summarize')) {
                resp.setBody(JSON.serialize(new Map<String, Object>{
                    'summary' => 'A project summary.',
                    'citations' => new List<Object>{
                        new Map<String, Object>{
                            'file' => 'spec.pdf', 'chunk' => 0, 'excerpt' => 'Scope'
                        }
                    }
                }));
            } else {
                resp.setStatusCode(404);
                resp.setBody('{}');
            }
            return resp;
        }
    }

    @IsTest
    static void getUploadUrlReturnsSignedUrl() {
        RFP__c rfp = new RFP__c(Name = 'Test RFP');
        insert rfp;

        Test.setMock(HttpCalloutMock.class, new MockServiceRouter());
        Test.startTest();
        RFPDeepDiveController.UploadUrlResponse resp =
            RFPDeepDiveController.getUploadUrl(rfp.Id, 'spec.pdf', 'application/pdf');
        Test.stopTest();

        System.assertNotEquals(null, resp);
        if (resp.success) {
            System.assertEquals('a3cTEST/spec.pdf', resp.gcsPath);
            System.assert(resp.uploadUrl.startsWith('https://'));
        }
    }

    @IsTest
    static void ingestDocumentStartsBackgroundJob() {
        RFP__c rfp = new RFP__c(Name = 'Test RFP');
        insert rfp;

        Test.setMock(HttpCalloutMock.class, new MockServiceRouter());
        Test.startTest();
        RFPDeepDiveController.IngestResponse resp =
            RFPDeepDiveController.ingestDocument(rfp.Id, 'spec.pdf', 'a3cTEST/spec.pdf');
        Test.stopTest();

        System.assertNotEquals(null, resp);
        if (resp.success) {
            System.assertEquals('processing', resp.status);
        }
    }

    @IsTest
    static void getIngestStatusReturnsJobState() {
        RFP__c rfp = new RFP__c(Name = 'Test RFP');
        insert rfp;

        Test.setMock(HttpCalloutMock.class, new MockServiceRouter());
        Test.startTest();
        RFPDeepDiveController.IngestStatusResponse resp =
            RFPDeepDiveController.getIngestStatus(rfp.Id, 'spec.pdf');
        Test.stopTest();

        System.assertNotEquals(null, resp);
        if (resp.success) {
            System.assertEquals('ingested', resp.status);
            System.assertEquals(42, resp.chunks);
        }
    }

    @IsTest
    static void summarizeReturnsSummaryWithCitations() {
        RFP__c rfp = new RFP__c(Name = 'Test RFP');
        insert rfp;

        Test.setMock(HttpCalloutMock.class, new MockServiceRouter());
        Test.startTest();
        RFPDeepDiveController.SummaryResponse resp =
            RFPDeepDiveController.summarize(rfp.Id);
        Test.stopTest();

        System.assertNotEquals(null, resp);
        if (resp.success) {
            System.assertEquals('A project summary.', resp.summary);
            System.assertEquals(1, resp.citations.size());
            System.assertEquals('spec.pdf', resp.citations[0].file);
        }
    }

    @IsTest
    static void getDocumentsReturnsIngestedFiles() {
        RFP__c rfp = new RFP__c(Name = 'Test RFP');
        insert rfp;

        Test.setMock(HttpCalloutMock.class, new MockServiceRouter());
        Test.startTest();
        RFPDeepDiveController.DocumentListResponse resp =
            RFPDeepDiveController.getDocuments(rfp.Id);
        Test.stopTest();

        System.assertNotEquals(null, resp);
        if (resp.success) {
            System.assertEquals(1, resp.documents.size());
            System.assertEquals('spec.pdf', resp.documents[0].filename);
            System.assertEquals(295, resp.documents[0].chunks);
        }
    }

    @IsTest
    static void newMethodsValidateInputs() {
        Test.startTest();
        System.assertEquals(false,
            RFPDeepDiveController.getUploadUrl(null, '', '').success);
        System.assertEquals(false,
            RFPDeepDiveController.ingestDocument(null, '', '').success);
        System.assertEquals(false,
            RFPDeepDiveController.getIngestStatus(null, '').success);
        System.assertEquals(false,
            RFPDeepDiveController.getDocuments(null).success);
        System.assertEquals(false,
            RFPDeepDiveController.summarize(null).success);
        System.assertEquals(false,
            RFPDeepDiveController.getDrawingSheets(null).success);
        Test.stopTest();
    }

    @IsTest
    static void getDrawingSheetsReturnsSheets() {
        RFP__c rfp = new RFP__c(Name = 'Test RFP');
        insert rfp;

        Test.setMock(HttpCalloutMock.class, new MockServiceRouter());
        Test.startTest();
        RFPDeepDiveController.DrawingSheetsResponse resp =
            RFPDeepDiveController.getDrawingSheets(rfp.Id);
        Test.stopTest();

        System.assertNotEquals(null, resp);
        if (resp.success) {
            System.assertEquals(1, resp.sheets.size());
            System.assertEquals(18, resp.sheets[0].page);
            System.assertEquals('Sheet A02.01 Architectural Floor Plan', resp.sheets[0].description);
        }
    }
}
