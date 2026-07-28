/**
 * @description Apex controller for the Relationship Hierarchy Viewer LWC.
 *              Relationship__c convention: Primary_Account__c = CHILD, Secondary_Account__c = PARENT.
 *              Schools use standard Account.ParentId to link to Districts.
 *              Everything else (District ↔ JPA ↔ State Entity ↔ JPA) uses Relationship__c.
 */
public with sharing class RelationshipHierarchyController {

    public class HierarchyResult {
        @AuraEnabled public String contextRecordType;
        @AuraEnabled public String contextAccountName;
        @AuraEnabled public List<HierarchyNode> parentEntities; 
        @AuraEnabled public List<HierarchyNode> childEntities; 
    }

    public class HierarchyNode {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String recordType;
        @AuraEnabled public String relationshipTypes;
        @AuraEnabled public String relationshipId;
        @AuraEnabled public Boolean hasChildren;
        @AuraEnabled public String accountUrl;
        @AuraEnabled public List<HierarchyNode> children;
    }

    // ─── Main Entry Point ────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static HierarchyResult getHierarchyData(Id accountId) {
        Account currentAccount = [
            SELECT Id, Name, ParentId, RecordType.DeveloperName
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        HierarchyResult result = new HierarchyResult();
        result.contextRecordType = currentAccount.RecordType.DeveloperName;
        result.contextAccountName = currentAccount.Name;
        result.parentEntities = new List<HierarchyNode>();
        result.childEntities = new List<HierarchyNode>();

        String rt = currentAccount.RecordType.DeveloperName;

        if (rt == 'JPA' || rt == 'State_Entity') {
            buildEntityHierarchy(currentAccount, result);
        } else if (rt == 'District') {
            buildDistrictHierarchy(currentAccount, result);
        } else if (rt == 'School') {
            buildSchoolHierarchy(currentAccount, result);
        }

        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<HierarchyNode> getChildSchools(Id districtId) {
        List<HierarchyNode> schoolNodes = new List<HierarchyNode>();
        for (Account school : [
            SELECT Id, Name, RecordType.DeveloperName
            FROM Account
            WHERE ParentId = :districtId
              AND RecordType.DeveloperName = 'School'
            ORDER BY Name
        ]) {
            schoolNodes.add(buildNode(school.Id, school.Name, 'School', null, null, false));
        }
        return schoolNodes;
    }

    @AuraEnabled(cacheable=true)
    public static List<HierarchyNode> getChildEntityRelationships(Id entityId) {
        return getChildrenOf(entityId);
    }

    /**
     * JPA / State Entity view:
     * - parentEntities = accounts where this entity is Primary (i.e., Secondary is the parent)
     * - childEntities  = accounts where this entity is Secondary (i.e., Primary is the child)
     * Each child entity eagerly loads ITS children too.
     */
    private static void buildEntityHierarchy(Account entity, HierarchyResult result) {
        for (Relationship__c rel : [
            SELECT Id, Secondary_Account__c, Secondary_Account__r.Name,
                   Secondary_Account__r.RecordType.DeveloperName,
                   Relationship_Type__c
            FROM Relationship__c
            WHERE Primary_Account__c = :entity.Id
            ORDER BY Secondary_Account__r.Name
        ]) {
            result.parentEntities.add(buildNode(
                rel.Secondary_Account__c,
                rel.Secondary_Account__r.Name,
                rel.Secondary_Account__r.RecordType.DeveloperName,
                rel.Relationship_Type__c,
                rel.Id,
                false
            ));
        }

        for (Relationship__c rel : [
            SELECT Id, Primary_Account__c, Primary_Account__r.Name,
                   Primary_Account__r.RecordType.DeveloperName,
                   Relationship_Type__c
            FROM Relationship__c
            WHERE Secondary_Account__c = :entity.Id
            ORDER BY Primary_Account__r.Name
        ]) {
            HierarchyNode childNode = buildNode(
                rel.Primary_Account__c,
                rel.Primary_Account__r.Name,
                rel.Primary_Account__r.RecordType.DeveloperName,
                rel.Relationship_Type__c,
                rel.Id,
                true
            );

            childNode.children = getChildrenOf(rel.Primary_Account__c);
            childNode.hasChildren = !childNode.children.isEmpty();

            result.childEntities.add(childNode);
        }
    }

    /**
     * District view:
     * - parentEntities = entities that are parents of this District
     *   (Relationship__c where Primary = this District → Secondary is ABOVE)
     * - childEntities  = empty (Schools are loaded lazily)
     */
    private static void buildDistrictHierarchy(Account district, HierarchyResult result) {
        for (Relationship__c rel : [
            SELECT Id, Secondary_Account__c, Secondary_Account__r.Name,
                   Secondary_Account__r.RecordType.DeveloperName,
                   Relationship_Type__c
            FROM Relationship__c
            WHERE Primary_Account__c = :district.Id
            ORDER BY Secondary_Account__r.Name
        ]) {
            result.parentEntities.add(buildNode(
                rel.Secondary_Account__c,
                rel.Secondary_Account__r.Name,
                rel.Secondary_Account__r.RecordType.DeveloperName,
                rel.Relationship_Type__c,
                rel.Id,
                false
            ));
        }
    }

    /**
     * School view:
     * - Get parent District via ParentId
     * - Then get the District's parents (its entity relationships)
     */
    private static void buildSchoolHierarchy(Account school, HierarchyResult result) {
        if (school.ParentId == null) {
            return;
        }

        Account district = [
            SELECT Id, Name, RecordType.DeveloperName
            FROM Account
            WHERE Id = :school.ParentId
            LIMIT 1
        ];

        HierarchyNode districtNode = buildNode(
            district.Id,
            district.Name,
            district.RecordType.DeveloperName,
            null, null, true
        );

        districtNode.children = new List<HierarchyNode>();
        for (Relationship__c rel : [
            SELECT Id, Secondary_Account__c, Secondary_Account__r.Name,
                   Secondary_Account__r.RecordType.DeveloperName,
                   Relationship_Type__c
            FROM Relationship__c
            WHERE Primary_Account__c = :district.Id
            ORDER BY Secondary_Account__r.Name
        ]) {
            districtNode.children.add(buildNode(
                rel.Secondary_Account__c,
                rel.Secondary_Account__r.Name,
                rel.Secondary_Account__r.RecordType.DeveloperName,
                rel.Relationship_Type__c,
                rel.Id,
                false
            ));
        }
        districtNode.hasChildren = !districtNode.children.isEmpty();

        result.parentEntities.add(districtNode);
    }

    /**
     * Get children of a given entity (records where this entity is Secondary → Primary is child).
     */
    private static List<HierarchyNode> getChildrenOf(Id entityId) {
        List<HierarchyNode> nodes = new List<HierarchyNode>();
        for (Relationship__c rel : [
            SELECT Id, Primary_Account__c, Primary_Account__r.Name,
                   Primary_Account__r.RecordType.DeveloperName,
                   Relationship_Type__c
            FROM Relationship__c
            WHERE Secondary_Account__c = :entityId
            ORDER BY Primary_Account__r.Name
        ]) {
            nodes.add(buildNode(
                rel.Primary_Account__c,
                rel.Primary_Account__r.Name,
                rel.Primary_Account__r.RecordType.DeveloperName,
                rel.Relationship_Type__c,
                rel.Id,
                false
            ));
        }
        return nodes;
    }

    private static HierarchyNode buildNode(
        Id accountId,
        String name,
        String recordType,
        String relationshipTypes,
        Id relationshipId,
        Boolean hasChildren
    ) {
        HierarchyNode node = new HierarchyNode();
        node.id = accountId;
        node.name = name;
        node.recordType = recordType;
        node.relationshipTypes = relationshipTypes;
        node.relationshipId = relationshipId;
        node.hasChildren = hasChildren;
        node.accountUrl = '/lightning/r/Account/' + accountId + '/view';
        node.children = new List<HierarchyNode>();
        return node;
    }
}
