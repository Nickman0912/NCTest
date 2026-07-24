/**
 * @description Service class handling business logic for Opportunity operations.
 */
public with sharing class OpportunityService {

    /**
     * @description Cascades Asset creation down the Account Hierarchy and Junction Relationships when Opportunities are Closed Won.
     * @param closedWonOpps List of Opportunities that transitioned to Closed Won.
     */
    public static void cascadeAssetsOnClosedWon(List<Opportunity> closedWonOpps) {
        if (closedWonOpps == null || closedWonOpps.isEmpty()) {
            return;
        }

        // 1. Collect target Account IDs, Relationship Types, and Product names
        Set<Id> secondaryAccountIds = new Set<Id>();
        Set<String> relTypes = new Set<String>();

        for (Opportunity opp : closedWonOpps) {
            if (opp.AccountId != null && String.isNotBlank(opp.Relationship_Type__c)) {
                secondaryAccountIds.add(opp.AccountId);
                relTypes.add(opp.Relationship_Type__c);
            }
        }

        if (secondaryAccountIds.isEmpty()) {
            return;
        }

        // Look up matching Product2 records by Name
        Map<String, Id> productMap = new Map<String, Id>();
        for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Name IN :relTypes AND IsActive = true]) {
            productMap.put(p.Name, p.Id);
        }

        // 2. Query all Relationship__c junction records where Secondary_Account__c IN :secondaryAccountIds
        List<Relationship__c> allRelationships = [
            SELECT Id, Primary_Account__c, Secondary_Account__c, Relationship_Type__c
            FROM Relationship__c
            WHERE Secondary_Account__c IN :secondaryAccountIds
              AND Primary_Account__c != null
        ];

        // Map SecondaryAccountId -> List of matching Relationship__c
        Map<Id, List<Relationship__c>> relsBySecondaryAccId = new Map<Id, List<Relationship__c>>();
        for (Relationship__c rel : allRelationships) {
            if (!relsBySecondaryAccId.containsKey(rel.Secondary_Account__c)) {
                relsBySecondaryAccId.put(rel.Secondary_Account__c, new List<Relationship__c>());
            }
            relsBySecondaryAccId.get(rel.Secondary_Account__c).add(rel);
        }

        // 3. For each closed opp, find matching Primary Accounts and query their Child Accounts
        Set<Id> allPrimaryAccountIds = new Set<Id>();
        for (Relationship__c rel : allRelationships) {
            allPrimaryAccountIds.add(rel.Primary_Account__c);
        }

        Map<Id, List<Account>> childAccountsByParentId = new Map<Id, List<Account>>();
        if (!allPrimaryAccountIds.isEmpty()) {
            for (Account child : [SELECT Id, Name, ParentId FROM Account WHERE ParentId IN :allPrimaryAccountIds]) {
                if (!childAccountsByParentId.containsKey(child.ParentId)) {
                    childAccountsByParentId.put(child.ParentId, new List<Account>());
                }
                childAccountsByParentId.get(child.ParentId).add(child);
            }
        }

        // 4. Construct Asset records
        List<Asset> assetsToInsert = new List<Asset>();
        Set<String> assetUniquenessKey = new Set<String>();

        for (Opportunity opp : closedWonOpps) {
            if (opp.AccountId == null || String.isBlank(opp.Relationship_Type__c)) {
                continue;
            }

            String oppType = opp.Relationship_Type__c;
            Id prodId = productMap.get(oppType);

            // Asset for Opportunity's direct Account
            String directKey = opp.AccountId + '-' + opp.Id + '-' + oppType;
            if (!assetUniquenessKey.contains(directKey)) {
                assetUniquenessKey.add(directKey);
                assetsToInsert.add(createAssetRecord(opp, opp.AccountId, prodId));
            }

            // Find matching relationships for this Opp's Account & Relationship Type
            List<Relationship__c> targetRels = relsBySecondaryAccId.get(opp.AccountId);
            if (targetRels != null) {
                for (Relationship__c rel : targetRels) {
                    if (isMatchingType(rel.Relationship_Type__c, oppType)) {
                        Id primaryAccId = rel.Primary_Account__c;

                        // Asset for Primary Account (District / JPA)
                        String primaryKey = primaryAccId + '-' + opp.Id + '-' + oppType;
                        if (!assetUniquenessKey.contains(primaryKey)) {
                            assetUniquenessKey.add(primaryKey);
                            assetsToInsert.add(createAssetRecord(opp, primaryAccId, prodId));
                        }

                        // Assets for Child Accounts (Schools)
                        List<Account> children = childAccountsByParentId.get(primaryAccId);
                        if (children != null) {
                            for (Account child : children) {
                                String childKey = child.Id + '-' + opp.Id + '-' + oppType;
                                if (!assetUniquenessKey.contains(childKey)) {
                                    assetUniquenessKey.add(childKey);
                                    assetsToInsert.add(createAssetRecord(opp, child.Id, prodId));
                                }
                            }
                        }
                    }
                }
            }
        }

        if (!assetsToInsert.isEmpty()) {
            insert assetsToInsert;
        }
    }

    /**
     * @description Helper to construct an Asset instance with Purchased_By__c set to the Opportunity's AccountId.
     */
    private static Asset createAssetRecord(Opportunity opp, Id targetAccountId, Id productId) {
        return new Asset(
            Name = opp.Name + ' - ' + opp.Relationship_Type__c,
            AccountId = targetAccountId,
            Purchased_By__c = opp.AccountId,
            Product2Id = productId,
            Status = 'Purchased',
            InstallDate = Date.today(),
            Description = 'Cascaded from Closed Won Opportunity: ' + opp.Name
        );
    }

    /**
     * @description Helper to check if a multiselect picklist string contains a specific value.
     */
    private static Boolean isMatchingType(String relTypeField, String oppType) {
        if (String.isBlank(relTypeField) || String.isBlank(oppType)) {
            return false;
        }
        List<String> values = relTypeField.split(';');
        for (String val : values) {
            if (val.trim().equalsIgnoreCase(oppType.trim())) {
                return true;
            }
        }
        return false;
    }
}
