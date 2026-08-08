// One-time setup: activate the Standard Price Book so OpportunityLineItems
// can be created on renewal Opportunities.
Pricebook2 stdPb = [
    SELECT Id, IsActive
    FROM Pricebook2
    WHERE IsStandard = true
    LIMIT 1
];

if (!stdPb.IsActive) {
    stdPb.IsActive = true;
    update stdPb;
    System.debug('Activated Standard Price Book: ' + stdPb.Id);
} else {
    System.debug('Standard Price Book already active: ' + stdPb.Id);
}