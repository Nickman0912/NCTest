// Create Product2 records for each Relationship_Type__c picklist value.
// Idempotent: skips any Product2 that already exists with the same Name.
List<String> typeValues = new List<String>{
    'Liability',
    'Workers Comp',
    'Product Line Alpha',
    'Product Line Beta',
    'Product Gamma',
    'Product Omega'
};

// Find existing products with these names
Set<String> existingNames = new Map<String, Product2>(
    [SELECT Id, Name FROM Product2 WHERE Name IN :typeValues]
).keySet();

List<Product2> toInsert = new List<Product2>();
for (String name : typeValues) {
    if (!existingNames.contains(name)) {
        toInsert.add(new Product2(
            Name = name,
            IsActive = true
        ));
    }
}

if (toInsert.isEmpty()) {
    System.debug('No new Product2 records needed — all already exist.');
} else {
    insert toInsert;
    System.debug('Inserted ' + toInsert.size() + ' Product2 record(s): ' + toInsert);
}