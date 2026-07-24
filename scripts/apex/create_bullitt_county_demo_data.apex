Id districtRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'District' LIMIT 1].Id;
Id schoolRtId   = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'School' LIMIT 1].Id;

Database.DMLOptions dmlOpt = new Database.DMLOptions();
dmlOpt.DuplicateRuleHeader.allowSave = true;
dmlOpt.DuplicateRuleHeader.runAsCurrentUser = true;

// 1. Create or retrieve Bullitt County Public Schools District Account
Account district;
List<Account> existingDistrict = [SELECT Id FROM Account WHERE Name = 'Bullitt County Public Schools' LIMIT 1];
if (!existingDistrict.isEmpty()) {
    district = existingDistrict[0];
} else {
    district = new Account(
        Name = 'Bullitt County Public Schools',
        RecordTypeId = districtRtId,
        BillingStreet = '1040 Highway 44 E',
        BillingCity = 'Shepherdsville',
        BillingState = 'KY',
        BillingPostalCode = '40165',
        Phone = '(502) 869-8000',
        Website = 'https://www.bullittschools.org',
        NumberOfEmployees = 1800,
        Description = 'Bullitt County Public Schools (BCPS) serves public school students in Bullitt County, Kentucky.'
    );
    Database.insert(district, dmlOpt);
}

// 2. Create 10 Child School Accounts linked via ParentId
List<Account> schoolsToInsert = new List<Account>();

schoolsToInsert.add(new Account(
    Name = 'Bullitt East High School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'High School',
    Grades_Served__c = '9-12',
    Student_Population__c = 1500,
    Faculty_Size__c = 90,
    BillingStreet = '11450 Highway 44 E',
    BillingCity = 'Mount Washington',
    BillingState = 'KY',
    BillingPostalCode = '40047',
    Website = 'https://behs.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Bullitt Central High School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'High School',
    Grades_Served__c = '9-12',
    Student_Population__c = 1400,
    Faculty_Size__c = 85,
    BillingStreet = '1330 Highway 44 E',
    BillingCity = 'Shepherdsville',
    BillingState = 'KY',
    BillingPostalCode = '40165',
    Website = 'https://bchs.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'North Bullitt High School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'High School',
    Grades_Served__c = '9-12',
    Student_Population__c = 1250,
    Faculty_Size__c = 75,
    BillingStreet = '3100 Hebron Ln',
    BillingCity = 'Shepherdsville',
    BillingState = 'KY',
    BillingPostalCode = '40165',
    Website = 'https://nbhs.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Eastside Middle School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Middle School',
    Grades_Served__c = '6-8',
    Student_Population__c = 750,
    Faculty_Size__c = 45,
    BillingStreet = '625 Mt Washington Rd',
    BillingCity = 'Mount Washington',
    BillingState = 'KY',
    BillingPostalCode = '40047',
    Website = 'https://ems.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Bernheim Middle School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Middle School',
    Grades_Served__c = '6-8',
    Student_Population__c = 720,
    Faculty_Size__c = 42,
    BillingStreet = '270 BGC Way',
    BillingCity = 'Shepherdsville',
    BillingState = 'KY',
    BillingPostalCode = '40165',
    Website = 'https://bms.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Zoneton Middle School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Middle School',
    Grades_Served__c = '6-8',
    Student_Population__c = 680,
    Faculty_Size__c = 40,
    BillingStreet = '334 Zoneton Rd',
    BillingCity = 'Shepherdsville',
    BillingState = 'KY',
    BillingPostalCode = '40165',
    Website = 'https://zms.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Mt. Washington Elementary School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Elementary School',
    Grades_Served__c = 'K-5',
    Student_Population__c = 600,
    Faculty_Size__c = 38,
    BillingStreet = '151 Battlefield Dr',
    BillingCity = 'Mount Washington',
    BillingState = 'KY',
    BillingPostalCode = '40047',
    Website = 'https://mwe.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Freedom Elementary School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Elementary School',
    Grades_Served__c = 'K-5',
    Student_Population__c = 550,
    Faculty_Size__c = 35,
    BillingStreet = '244 Professional Pl',
    BillingCity = 'Shepherdsville',
    BillingState = 'KY',
    BillingPostalCode = '40165',
    Website = 'https://fes.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Pleasant Grove Elementary School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Elementary School',
    Grades_Served__c = 'K-5',
    Student_Population__c = 580,
    Faculty_Size__c = 36,
    BillingStreet = '281 Heritage Dr',
    BillingCity = 'Mount Washington',
    BillingState = 'KY',
    BillingPostalCode = '40047',
    Website = 'https://pge.bullittschools.org'
));

schoolsToInsert.add(new Account(
    Name = 'Overdale Elementary School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Elementary School',
    Grades_Served__c = 'K-5',
    Student_Population__c = 520,
    Faculty_Size__c = 33,
    BillingStreet = '6510 Overdale Dr',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40229',
    Website = 'https://oes.bullittschools.org'
));

Database.insert(schoolsToInsert, dmlOpt);

// 3. Create 3 Relationship__c records for Bullitt County Public Schools
Account kde  = [SELECT Id FROM Account WHERE Name = 'Kentucky Department of Education' LIMIT 1];
Account ksbe = [SELECT Id FROM Account WHERE Name = 'Kentucky State Board of Education' LIMIT 1];
Account ovec = [SELECT Id FROM Account WHERE Name = 'Ohio Valley Educational Cooperative' LIMIT 1];

List<Relationship__c> relsToInsert = new List<Relationship__c>();

// Bullitt -> KDE (Product Gamma)
relsToInsert.add(new Relationship__c(
    Primary_Account__c = district.Id,
    Secondary_Account__c = kde.Id,
    Relationship_Type__c = 'Product Gamma'
));

// Bullitt -> KSBE (Product Line Beta)
relsToInsert.add(new Relationship__c(
    Primary_Account__c = district.Id,
    Secondary_Account__c = ksbe.Id,
    Relationship_Type__c = 'Product Line Beta'
));

// Bullitt -> OVEC (Liability, Workers Comp)
relsToInsert.add(new Relationship__c(
    Primary_Account__c = district.Id,
    Secondary_Account__c = ovec.Id,
    Relationship_Type__c = 'Liability;Workers Comp'
));

insert relsToInsert;
System.debug('Successfully inserted Bullitt County District, 10 child schools, and 3 relationship junction records.');
