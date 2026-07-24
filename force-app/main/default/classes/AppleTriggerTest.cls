@isTest
public class AppleTriggerTest 
{
	@isTest static void InsertOpp()
    {
        Opportunity opp = new Opportunity();
        opp.Name = 'Test Name';
        opp.CloseDate = date.Today();
        opp.stagename = 'Prospecting';
        insert opp;
    }
}