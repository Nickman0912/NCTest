/**
 * @description Apex controller for the Asset Viewer LWC.
 *              Queries Assets for a given Account and groups them by Purchased_By__c.
 */
public with sharing class AssetViewerController {

    /**
     * Wrapper returned to the LWC — top-level summary + purchaser groups.
     */
    public class AssetViewerResult {
        @AuraEnabled public Integer totalAssets;
        @AuraEnabled public Integer totalPurchasers;
        @AuraEnabled public String accountName;
        @AuraEnabled public List<PurchaserGroup> purchaserGroups;
    }

    /**
     * One group of assets sharing the same Purchased_By__c account.
     */
    public class PurchaserGroup {
        @AuraEnabled public String purchaserId;
        @AuraEnabled public String purchaserName;
        @AuraEnabled public String purchaserRecordType;
        @AuraEnabled public String purchaserUrl;
        @AuraEnabled public Boolean isSelf;
        @AuraEnabled public Integer assetCount;
        @AuraEnabled public List<AssetRecord> assets;
    }

    /**
     * Lightweight representation of a single Asset record.
     */
    public class AssetRecord {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String productName;
        @AuraEnabled public String status;
        @AuraEnabled public Date installDate;
        @AuraEnabled public String description;
        @AuraEnabled public String assetUrl;
        @AuraEnabled public Decimal price;
        @AuraEnabled public Decimal quantity;
    }

    /**
     * @description Main entry point — returns all assets for the given account grouped by purchaser.
     * @param accountId The Account whose assets to load.
     * @return AssetViewerResult containing grouped asset data.
     */
    @AuraEnabled(cacheable=true)
    public static AssetViewerResult getAssetsForAccount(Id accountId) {

        // Get the context account name
        Account ctx = [SELECT Id, Name FROM Account WHERE Id = :accountId LIMIT 1];

        // Query all assets belonging to this account
        List<Asset> assets = [
            SELECT Id, Name, Status, InstallDate, Description, Price, Quantity,
                   Product2Id, Product2.Name,
                   Purchased_By__c, Purchased_By__r.Name,
                   Purchased_By__r.RecordType.DeveloperName
            FROM Asset
            WHERE AccountId = :accountId
            ORDER BY Purchased_By__r.Name NULLS LAST, Name
        ];

        // Group by Purchased_By__c
        Map<Id, PurchaserGroup> groupMap = new Map<Id, PurchaserGroup>();
        // A special key for assets with no Purchased_By__c
        Id selfKey = accountId;
        List<AssetRecord> noPurchaserAssets = new List<AssetRecord>();

        for (Asset a : assets) {
            AssetRecord ar = mapAsset(a);

            Id purchaserId = a.Purchased_By__c;
            if (purchaserId == null) {
                purchaserId = selfKey;
            }

            if (!groupMap.containsKey(purchaserId)) {
                PurchaserGroup pg = new PurchaserGroup();
                pg.purchaserId = purchaserId;
                pg.assets = new List<AssetRecord>();
                pg.assetCount = 0;

                if (a.Purchased_By__c != null) {
                    pg.purchaserName = a.Purchased_By__r.Name;
                    pg.purchaserRecordType = a.Purchased_By__r.RecordType != null
                        ? a.Purchased_By__r.RecordType.DeveloperName : '';
                } else {
                    pg.purchaserName = ctx.Name;
                    pg.purchaserRecordType = '';
                }

                pg.purchaserUrl = '/lightning/r/Account/' + purchaserId + '/view';
                pg.isSelf = (purchaserId == accountId);
                groupMap.put(purchaserId, pg);
            }

            PurchaserGroup grp = groupMap.get(purchaserId);
            grp.assets.add(ar);
            grp.assetCount = grp.assets.size();
        }

        // Sort groups: self first, then by asset count descending
        List<PurchaserGroup> sortedGroups = new List<PurchaserGroup>();
        PurchaserGroup selfGroup = groupMap.remove(accountId);
        if (selfGroup != null) {
            sortedGroups.add(selfGroup);
        }

        // Remaining groups sorted by asset count desc
        List<PurchaserGroup> otherGroups = groupMap.values();
        otherGroups.sort(new PurchaserGroupComparator());
        sortedGroups.addAll(otherGroups);

        // Build result
        AssetViewerResult result = new AssetViewerResult();
        result.totalAssets = assets.size();
        result.totalPurchasers = sortedGroups.size();
        result.accountName = ctx.Name;
        result.purchaserGroups = sortedGroups;
        return result;
    }

    /**
     * @description Maps an Asset SObject to the lightweight AssetRecord wrapper.
     */
    private static AssetRecord mapAsset(Asset a) {
        AssetRecord ar = new AssetRecord();
        ar.id = a.Id;
        ar.name = a.Name;
        ar.productName = a.Product2Id != null ? a.Product2.Name : '';
        ar.status = a.Status != null ? a.Status : '';
        ar.installDate = a.InstallDate;
        ar.description = a.Description;
        ar.assetUrl = '/lightning/r/Asset/' + a.Id + '/view';
        ar.price = a.Price;
        ar.quantity = a.Quantity;
        return ar;
    }

    /**
     * @description Comparator to sort PurchaserGroups by asset count descending.
     */
    private class PurchaserGroupComparator implements Comparator<PurchaserGroup> {
        public Integer compare(PurchaserGroup a, PurchaserGroup b) {
            // Descending order
            return b.assetCount - a.assetCount;
        }
    }
}
