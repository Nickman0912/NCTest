/**
 * @description Test class for AssetViewerController.
 */
@isTest
private class AssetViewerControllerTest {

    @TestSetup
    static void setupData() {
        // Create record types — use existing ones if available
        // We'll work with generic accounts if record types aren't available in test context

        // Purchaser account (e.g., a JPA or State Entity)
        Account purchaserAccount = new Account(Name = 'Test Purchaser JPA');
        insert purchaserAccount;

        // Target account (e.g., a District)
        Account targetAccount = new Account(Name = 'Test District Account');
        insert targetAccount;

        // Second purchaser
        Account secondPurchaser = new Account(Name = 'Second Purchaser');
        insert secondPurchaser;

        // Create a Product
        Product2 prod = new Product2(Name = 'Test Product', IsActive = true);
        insert prod;

        Product2 prod2 = new Product2(Name = 'Another Product', IsActive = true);
        insert prod2;

        // Create Assets on the target account purchased by the purchaser
        List<Asset> assets = new List<Asset>();
        for (Integer i = 1; i <= 3; i++) {
            assets.add(new Asset(
                Name = 'Asset ' + i + ' from Purchaser 1',
                AccountId = targetAccount.Id,
                Purchased_By__c = purchaserAccount.Id,
                Product2Id = prod.Id,
                Status = 'Purchased',
                InstallDate = Date.today(),
                Description = 'Test asset ' + i
            ));
        }

        // Assets from second purchaser
        for (Integer i = 1; i <= 2; i++) {
            assets.add(new Asset(
                Name = 'Asset ' + i + ' from Purchaser 2',
                AccountId = targetAccount.Id,
                Purchased_By__c = secondPurchaser.Id,
                Product2Id = prod2.Id,
                Status = 'Installed',
                InstallDate = Date.today().addDays(-30),
                Description = 'Test asset from second purchaser ' + i
            ));
        }

        // Self-purchased asset (Purchased_By = the target itself)
        assets.add(new Asset(
            Name = 'Self-Purchased Asset',
            AccountId = targetAccount.Id,
            Purchased_By__c = targetAccount.Id,
            Product2Id = prod.Id,
            Status = 'Purchased',
            InstallDate = Date.today()
        ));

        // Asset with null Purchased_By
        assets.add(new Asset(
            Name = 'Orphan Asset',
            AccountId = targetAccount.Id,
            Purchased_By__c = null,
            Product2Id = null,
            Status = 'Obsolete',
            InstallDate = null
        ));

        insert assets;
    }

    @isTest
    static void testGetAssetsForAccount_ReturnsGroupedData() {
        Account target = [SELECT Id FROM Account WHERE Name = 'Test District Account' LIMIT 1];

        Test.startTest();
        AssetViewerController.AssetViewerResult result =
            AssetViewerController.getAssetsForAccount(target.Id);
        Test.stopTest();

        // Verify totals
        System.assertEquals(7, result.totalAssets, 'Should have 7 total assets');
        System.assertEquals('Test District Account', result.accountName, 'Account name should match');

        // There should be 3 purchaser groups:
        // 1. Self (targetAccount — self-purchased + orphan with null Purchased_By)
        // 2. Test Purchaser JPA (3 assets)
        // 3. Second Purchaser (2 assets)
        System.assertEquals(3, result.purchaserGroups.size(), 'Should have 3 purchaser groups');

        // First group should be "self"
        AssetViewerController.PurchaserGroup selfGroup = result.purchaserGroups[0];
        System.assertEquals(true, selfGroup.isSelf, 'First group should be self');
        System.assertEquals(2, selfGroup.assetCount, 'Self group should have 2 assets');

        // Verify other groups have correct counts (sorted by count desc)
        AssetViewerController.PurchaserGroup group2 = result.purchaserGroups[1];
        System.assertEquals(3, group2.assetCount, 'Second group should have 3 assets');
        System.assertEquals(false, group2.isSelf, 'Second group should not be self');

        AssetViewerController.PurchaserGroup group3 = result.purchaserGroups[2];
        System.assertEquals(2, group3.assetCount, 'Third group should have 2 assets');
    }

    @isTest
    static void testGetAssetsForAccount_NoAssets() {
        Account noAssets = new Account(Name = 'Empty Account');
        insert noAssets;

        Test.startTest();
        AssetViewerController.AssetViewerResult result =
            AssetViewerController.getAssetsForAccount(noAssets.Id);
        Test.stopTest();

        System.assertEquals(0, result.totalAssets, 'Should have 0 assets');
        System.assertEquals(0, result.totalPurchasers, 'Should have 0 purchaser groups');
        System.assertEquals('Empty Account', result.accountName);
        System.assert(result.purchaserGroups.isEmpty(), 'Groups list should be empty');
    }

    @isTest
    static void testAssetRecordFields() {
        Account target = [SELECT Id FROM Account WHERE Name = 'Test District Account' LIMIT 1];

        Test.startTest();
        AssetViewerController.AssetViewerResult result =
            AssetViewerController.getAssetsForAccount(target.Id);
        Test.stopTest();

        // Find an asset from the first purchaser group (non-self) to validate fields
        AssetViewerController.AssetRecord ar = null;
        for (AssetViewerController.PurchaserGroup pg : result.purchaserGroups) {
            for (AssetViewerController.AssetRecord a : pg.assets) {
                if (a.name != null && a.name.contains('from Purchaser 1')) {
                    ar = a;
                    break;
                }
            }
            if (ar != null) break;
        }

        System.assertNotEquals(null, ar, 'Should find an asset from Purchaser 1');
        System.assertNotEquals(null, ar.id, 'Asset Id should be populated');
        System.assertEquals('Test Product', ar.productName, 'Product name should match');
        System.assertEquals('Purchased', ar.status, 'Status should match');
        System.assertEquals(Date.today(), ar.installDate, 'Install date should match');
        System.assert(ar.assetUrl.contains('/lightning/r/Asset/'), 'Asset URL should be populated');
    }

    @isTest
    static void testPurchaserGroupUrls() {
        Account target = [SELECT Id FROM Account WHERE Name = 'Test District Account' LIMIT 1];

        Test.startTest();
        AssetViewerController.AssetViewerResult result =
            AssetViewerController.getAssetsForAccount(target.Id);
        Test.stopTest();

        for (AssetViewerController.PurchaserGroup pg : result.purchaserGroups) {
            System.assert(
                pg.purchaserUrl.contains('/lightning/r/Account/'),
                'Purchaser URL should be an Account URL'
            );
            System.assertNotEquals(null, pg.purchaserName, 'Purchaser name should not be null');
        }
    }
}
