List<String> productNames = new List<String>{
    'Liability',
    'Workers Comp',
    'Product Line Alpha',
    'Product Line Beta',
    'Product Gamma'
};

List<Product2> existingProducts = [SELECT Id, Name FROM Product2 WHERE Name IN :productNames];
Set<String> existingNames = new Set<String>();
for (Product2 p : existingProducts) {
    existingNames.add(p.Name);
}

List<Product2> productsToInsert = new List<Product2>();
for (String pName : productNames) {
    if (!existingNames.contains(pName)) {
        productsToInsert.add(new Product2(
            Name = pName,
            IsActive = true,
            Description = 'Product record corresponding to Relationship Type: ' + pName
        ));
    }
}

if (!productsToInsert.isEmpty()) {
    insert productsToInsert;
    System.debug('Inserted ' + productsToInsert.size() + ' new products.');
} else {
    System.debug('All products already exist.');
}
