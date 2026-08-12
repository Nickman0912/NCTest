RFPDeepDiveController.AskResponse resp = RFPDeepDiveController.ask('a3cg8000000apbtAAA', 'What are the vendor qualification requirements?');
System.debug('SUCCESS: ' + resp.success);
System.debug('ANSWER: ' + resp.answer);
System.debug('ERROR: ' + resp.errorMessage);
