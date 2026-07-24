Id jpaRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'JPA' LIMIT 1].Id;
Id stateEntityRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'State_Entity' LIMIT 1].Id;

// 1. Retrieve JCPS District Account
Account jcps = [SELECT Id FROM Account WHERE Name = 'Jefferson County Public Schools' LIMIT 1];

// 2. Create/upsert 2 JPA Accounts
Account kedc = new Account(
    Name = 'Kentucky Educational Development Corporation',
    RecordTypeId = jpaRtId,
    BillingStreet = '904 Rose Rd',
    BillingCity = 'Ashland',
    BillingState = 'KY',
    BillingPostalCode = '41102',
    Phone = '(606) 928-3351',
    Website = 'https://www.kedc.org',
    Description = 'Kentucky Educational Development Corporation (KEDC)'
);

Account ovec = new Account(
    Name = 'Ohio Valley Educational Cooperative',
    RecordTypeId = jpaRtId,
    BillingStreet = '100 Loop Rd',
    BillingCity = 'Shelbyville',
    BillingState = 'KY',
    BillingPostalCode = '40065',
    Phone = '(502) 647-3533',
    Website = 'https://www.ovec.org',
    Description = 'Ohio Valley Educational Cooperative (OVEC)'
);

// 3. Create/upsert 2 State Entity Accounts
Account kde = new Account(
    Name = 'Kentucky Department of Education',
    RecordTypeId = stateEntityRtId,
    BillingStreet = '300 Sower Blvd, 5th Floor',
    BillingCity = 'Frankfort',
    BillingState = 'KY',
    BillingPostalCode = '40601',
    Phone = '(502) 564-4770',
    Website = 'https://education.ky.gov',
    Description = 'Kentucky Department of Education (KDE)'
);

Account ksbe = new Account(
    Name = 'Kentucky State Board of Education',
    RecordTypeId = stateEntityRtId,
    BillingStreet = '300 Sower Blvd, 5th Floor',
    BillingCity = 'Frankfort',
    BillingState = 'KY',
    BillingPostalCode = '40601',
    Phone = '(502) 564-3141',
    Website = 'https://education.ky.gov/KBE',
    Description = 'Kentucky State Board of Education (KSBE)'
);

List<Account> accountsToInsert = new List<Account>{ kedc, ovec, kde, ksbe };
insert accountsToInsert;

// 4. Create 4 Relationship__c Junction Records
List<Relationship__c> relsToInsert = new List<Relationship__c>();

// JCPS -> KEDC (Liability, Product Line Alpha)
relsToInsert.add(new Relationship__c(
    Primary_Account__c = jcps.Id,
    Secondary_Account__c = kedc.Id,
    Relationship_Type__c = 'Liability;Product Line Alpha'
));

// JCPS -> OVEC (Workers Comp)
relsToInsert.add(new Relationship__c(
    Primary_Account__c = jcps.Id,
    Secondary_Account__c = ovec.Id,
    Relationship_Type__c = 'Workers Comp'
));

// JCPS -> KDE (Product Gamma)
relsToInsert.add(new Relationship__c(
    Primary_Account__c = jcps.Id,
    Secondary_Account__c = kde.Id,
    Relationship_Type__c = 'Product Gamma'
));

// JCPS -> KSBE (Product Line Beta)
relsToInsert.add(new Relationship__c(
    Primary_Account__c = jcps.Id,
    Secondary_Account__c = ksbe.Id,
    Relationship_Type__c = 'Product Line Beta'
));

insert relsToInsert;
System.debug('Successfully inserted ' + relsToInsert.size() + ' relationship junction records.');
