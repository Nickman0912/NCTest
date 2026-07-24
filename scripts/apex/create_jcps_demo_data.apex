Id districtRtId = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'District' LIMIT 1].Id;
Id schoolRtId   = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND DeveloperName = 'School' LIMIT 1].Id;

// 1. Create or retrieve District Account
Account district;
List<Account> existingDistrict = [SELECT Id FROM Account WHERE Name = 'Jefferson County Public Schools' LIMIT 1];
if (!existingDistrict.isEmpty()) {
    district = existingDistrict[0];
} else {
    district = new Account(
        Name = 'Jefferson County Public Schools',
        RecordTypeId = districtRtId,
        BillingStreet = '3332 Newburg Rd',
        BillingCity = 'Louisville',
        BillingState = 'KY',
        BillingPostalCode = '40218',
        Phone = '(502) 485-3011',
        Website = 'https://www.jefferson.kyschools.us',
        NumberOfEmployees = 17000,
        Description = 'Jefferson County Public Schools (JCPS) is the public school district serving Jefferson County, Kentucky.'
    );
    insert district;
}

// 2. Create 10 Child School Accounts linked via ParentId (Account Hierarchy)
List<Account> schoolsToInsert = new List<Account>();

schoolsToInsert.add(new Account(
    Name = 'Brandeis Elementary School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Elementary School',
    Grades_Served__c = 'K-5',
    Student_Population__c = 550,
    Faculty_Size__c = 40,
    BillingStreet = '2817 W Kentucky St',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40211',
    Website = 'https://brandeis.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Meyzeek Middle School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Middle School',
    Grades_Served__c = '6-8',
    Student_Population__c = 980,
    Faculty_Size__c = 65,
    BillingStreet = '828 S Jackson St',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40203',
    Website = 'https://meyzeek.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'duPont Manual High School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'High School',
    Grades_Served__c = '9-12',
    Student_Population__c = 1920,
    Faculty_Size__c = 115,
    BillingStreet = '120 W Lee St',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40208',
    Website = 'https://manual.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Louisville Male High School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'High School',
    Grades_Served__c = '9-12',
    Student_Population__c = 2050,
    Faculty_Size__c = 120,
    BillingStreet = '4409 Preston Hwy',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40213',
    Website = 'https://male.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Ballard High School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'High School',
    Grades_Served__c = '9-12',
    Student_Population__c = 1850,
    Faculty_Size__c = 110,
    BillingStreet = '6000 Brownsboro Rd',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40222',
    Website = 'https://ballard.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Atherton High School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'High School',
    Grades_Served__c = '9-12',
    Student_Population__c = 1450,
    Faculty_Size__c = 90,
    BillingStreet = '3000 Dundee Rd',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40205',
    Website = 'https://atherton.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Noe Middle School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Middle School',
    Grades_Served__c = '6-8',
    Student_Population__c = 890,
    Faculty_Size__c = 55,
    BillingStreet = '1219 S 2nd St',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40203',
    Website = 'https://noe.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Highland Middle School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Middle School',
    Grades_Served__c = '6-8',
    Student_Population__c = 820,
    Faculty_Size__c = 50,
    BillingStreet = '1700 Bardstown Rd',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40204',
    Website = 'https://highland.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Greathouse Shryock Traditional Elementary',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Elementary School',
    Grades_Served__c = 'K-5',
    Student_Population__c = 620,
    Faculty_Size__c = 42,
    BillingStreet = '2700 Grandview Ave',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40207',
    Website = 'https://greathouse.jefferson.kyschools.us'
));

schoolsToInsert.add(new Account(
    Name = 'Lowe Elementary School',
    RecordTypeId = schoolRtId,
    ParentId = district.Id,
    School_Type__c = 'Elementary School',
    Grades_Served__c = 'K-5',
    Student_Population__c = 580,
    Faculty_Size__c = 38,
    BillingStreet = '210 S Hubbards Ln',
    BillingCity = 'Louisville',
    BillingState = 'KY',
    BillingPostalCode = '40207',
    Website = 'https://lowe.jefferson.kyschools.us'
));

insert schoolsToInsert;
System.debug('Successfully inserted ' + schoolsToInsert.size() + ' school accounts linked to District Id ' + district.Id);
