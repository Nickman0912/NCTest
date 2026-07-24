/**
 * @description Trigger handler class for OpportunityTrigger.
 */
public with sharing class OpportunityTriggerHandler {

    /**
     * @description Handles afterUpdate trigger event logic.
     * @param newOpps List of updated Opportunities (Trigger.new).
     * @param oldOppMap Map of old Opportunities (Trigger.oldMap).
     */
    public static void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        List<Opportunity> closedWonOpps = new List<Opportunity>();

        for (Opportunity newOpp : newOpps) {
            Opportunity oldOpp = oldOppMap != null ? oldOppMap.get(newOpp.Id) : null;

            // Check if Opportunity transitioned to Closed Won with a Relationship_Type__c set
            Boolean justClosedWon = (newOpp.StageName == 'Closed Won' && (oldOpp == null || oldOpp.StageName != 'Closed Won'));

            if (justClosedWon && newOpp.AccountId != null && String.isNotBlank(newOpp.Relationship_Type__c)) {
                closedWonOpps.add(newOpp);
            }
        }

        if (!closedWonOpps.isEmpty()) {
            OpportunityService.cascadeAssetsOnClosedWon(closedWonOpps);
        }
    }
}
