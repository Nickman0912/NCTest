Account ovec = [SELECT Id FROM Account WHERE Name = 'Ohio Valley Educational Cooperative' LIMIT 1];
Id raptorSaleRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Opportunity' AND DeveloperName = 'Raptor_Sale' LIMIT 1].Id;

List<Opportunity> oppsToInsert = new List<Opportunity>();

oppsToInsert.add(new Opportunity(
    Name = 'OVEC - Workers Comp Deal',
    AccountId = ovec.Id,
    RecordTypeId = raptorSaleRtId,
    Relationship_Type__c = 'Workers Comp',
    StageName = 'Prospecting',
    Amount = 75000,
    CloseDate = Date.today().addDays(30),
    Description = 'Raptor Sale opportunity for OVEC Workers Comp.'
));

oppsToInsert.add(new Opportunity(
    Name = 'OVEC - Liability Insurance Deal',
    AccountId = ovec.Id,
    RecordTypeId = raptorSaleRtId,
    Relationship_Type__c = 'Liability',
    StageName = 'Qualification',
    Amount = 120000,
    CloseDate = Date.today().addDays(45),
    Description = 'Raptor Sale opportunity for OVEC Liability Insurance.'
));

insert oppsToInsert;
System.debug('Successfully inserted ' + oppsToInsert.size() + ' OVEC opportunities.');
