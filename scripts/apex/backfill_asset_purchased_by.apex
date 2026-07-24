Account ovec = [SELECT Id FROM Account WHERE Name = 'Ohio Valley Educational Cooperative' LIMIT 1];

List<Asset> existingAssets = [SELECT Id, Purchased_By__c FROM Asset WHERE Purchased_By__c = null];
for (Asset a : existingAssets) {
    a.Purchased_By__c = ovec.Id;
}

if (!existingAssets.isEmpty()) {
    update existingAssets;
    System.debug('Successfully backfilled Purchased_By__c on ' + existingAssets.size() + ' Asset records with OVEC Account ID (' + ovec.Id + ').');
} else {
    System.debug('No Assets found with null Purchased_By__c.');
}
