Opportunity opp = [SELECT Id, Name, StageName, Relationship_Type__c, AccountId FROM Opportunity WHERE Name = 'OVEC - Workers Comp Deal' LIMIT 1];
opp.StageName = 'Closed Won';
update opp;
System.debug('Updated Opportunity to Closed Won: ' + opp.Name);
