@isTest
private class RelationshipHierarchyControllerTest {

    @TestSetup
    static void setupData() {
        // Record Types
        Id jpaRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('JPA').getRecordTypeId();
        Id districtRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('District').getRecordTypeId();
        Id schoolRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('School').getRecordTypeId();

        Account parentJpa = new Account(Name = 'Test Parent JPA', RecordTypeId = jpaRtId);
        insert parentJpa;

        Account childJpa = new Account(Name = 'Test Child JPA', RecordTypeId = jpaRtId);
        insert childJpa;

        Account district = new Account(Name = 'Test District', RecordTypeId = districtRtId);
        insert district;

        Account school = new Account(Name = 'Test School', RecordTypeId = schoolRtId, ParentId = district.Id);
        insert school;

        // Child JPA → Parent JPA (Primary = child, Secondary = parent)
        insert new Relationship__c(
            Primary_Account__c = childJpa.Id,
            Secondary_Account__c = parentJpa.Id,
            Relationship_Type__c = 'Product Omega'
        );

        // District → Parent JPA (Primary = child district, Secondary = parent JPA)
        insert new Relationship__c(
            Primary_Account__c = district.Id,
            Secondary_Account__c = childJpa.Id,
            Relationship_Type__c = 'Workers Comp'
        );
    }

    @isTest
    static void testJpaHierarchy() {
        Account parentJpa = [SELECT Id FROM Account WHERE Name = 'Test Parent JPA' LIMIT 1];

        Test.startTest();
        RelationshipHierarchyController.HierarchyResult result =
            RelationshipHierarchyController.getHierarchyData(parentJpa.Id);
        Test.stopTest();

        System.assertEquals('JPA', result.contextRecordType);
        System.assertEquals('Test Parent JPA', result.contextAccountName);
        // Parent JPA has no parents
        System.assertEquals(0, result.parentEntities.size());
        // Parent JPA has one child (the child JPA)
        System.assertEquals(1, result.childEntities.size());
        System.assertEquals('Test Child JPA', result.childEntities[0].name);
    }

    @isTest
    static void testChildJpaHierarchy() {
        Account childJpa = [SELECT Id FROM Account WHERE Name = 'Test Child JPA' LIMIT 1];

        Test.startTest();
        RelationshipHierarchyController.HierarchyResult result =
            RelationshipHierarchyController.getHierarchyData(childJpa.Id);
        Test.stopTest();

        System.assertEquals('JPA', result.contextRecordType);
        // Child JPA has parent (the parent JPA)
        System.assertEquals(1, result.parentEntities.size());
        System.assertEquals('Test Parent JPA', result.parentEntities[0].name);
        // Child JPA has one child (the district)
        System.assertEquals(1, result.childEntities.size());
        System.assertEquals('Test District', result.childEntities[0].name);
    }

    @isTest
    static void testDistrictHierarchy() {
        Account district = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];

        Test.startTest();
        RelationshipHierarchyController.HierarchyResult result =
            RelationshipHierarchyController.getHierarchyData(district.Id);
        Test.stopTest();

        System.assertEquals('District', result.contextRecordType);
        // District has parent entity (the child JPA)
        System.assertEquals(1, result.parentEntities.size());
        System.assertEquals('Test Child JPA', result.parentEntities[0].name);
    }

    @isTest
    static void testSchoolHierarchy() {
        Account school = [SELECT Id FROM Account WHERE Name = 'Test School' LIMIT 1];

        Test.startTest();
        RelationshipHierarchyController.HierarchyResult result =
            RelationshipHierarchyController.getHierarchyData(school.Id);
        Test.stopTest();

        System.assertEquals('School', result.contextRecordType);
        // School's parent is the District (via ParentId)
        System.assertEquals(1, result.parentEntities.size());
        System.assertEquals('Test District', result.parentEntities[0].name);
        // The district node should have its own children (entities above it)
        System.assert(result.parentEntities[0].children.size() > 0);
    }

    @isTest
    static void testGetChildSchools() {
        Account district = [SELECT Id FROM Account WHERE Name = 'Test District' LIMIT 1];

        Test.startTest();
        List<RelationshipHierarchyController.HierarchyNode> schools =
            RelationshipHierarchyController.getChildSchools(district.Id);
        Test.stopTest();

        System.assertEquals(1, schools.size());
        System.assertEquals('Test School', schools[0].name);
    }

    @isTest
    static void testGetChildEntityRelationships() {
        Account childJpa = [SELECT Id FROM Account WHERE Name = 'Test Child JPA' LIMIT 1];

        Test.startTest();
        List<RelationshipHierarchyController.HierarchyNode> children =
            RelationshipHierarchyController.getChildEntityRelationships(childJpa.Id);
        Test.stopTest();

        System.assertEquals(1, children.size());
        System.assertEquals('Test District', children[0].name);
    }
}
