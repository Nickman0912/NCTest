// 1. Create Product Omega in Product2
List<Product2> existingProd = [SELECT Id FROM Product2 WHERE Name = 'Product Omega' LIMIT 1];
if (existingProd.isEmpty()) {
    insert new Product2(
        Name = 'Product Omega',
        IsActive = true,
        Description = 'Product record corresponding to Relationship Type: Product Omega'
    );
    System.debug('Created Product2: Product Omega');
}

// 2. Create 2 new JPA Accounts
Id jpaRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'JPA' LIMIT 1].Id;

Account megaJpa = new Account(
    Name = 'Mega Kentucky JPA',
    RecordTypeId = jpaRtId,
    BillingState = 'KY',
    BillingCity = 'Lexington',
    Website = 'https://www.megakyjpa.org',
    Description = 'Mega Kentucky Joint Powers Authority'
);

Account techCoop = new Account(
    Name = 'Kentucky Technical School Cooperative',
    RecordTypeId = jpaRtId,
    BillingState = 'KY',
    BillingCity = 'Louisville',
    Website = 'https://www.kytechcoop.org',
    Description = 'Kentucky Technical School Cooperative'
);

Database.DMLOptions dmlOpt = new Database.DMLOptions();
dmlOpt.DuplicateRuleHeader.allowSave = true;
dmlOpt.DuplicateRuleHeader.runAsCurrentUser = true;

Database.insert(new List<Account>{ megaJpa, techCoop }, dmlOpt);

// 3. Create 2 Relationship__c records with Mega Kentucky JPA as Secondary Account
Account ovec = [SELECT Id FROM Account WHERE Name = 'Ohio Valley Educational Cooperative' LIMIT 1];

List<Relationship__c> relsToInsert = new List<Relationship__c>();

// Tech Coop (Primary) -> Mega Kentucky JPA (Secondary) with Product Omega
relsToInsert.add(new Relationship__c(
    Primary_Account__c = techCoop.Id,
    Secondary_Account__c = megaJpa.Id,
    Relationship_Type__c = 'Product Omega'
));

// OVEC (Primary) -> Mega Kentucky JPA (Secondary) with Product Omega
relsToInsert.add(new Relationship__c(
    Primary_Account__c = ovec.Id,
    Secondary_Account__c = megaJpa.Id,
    Relationship_Type__c = 'Product Omega'
));

insert relsToInsert;
System.debug('Successfully created 2 JPA accounts, Product Omega, and 2 Relationship junction records.');
