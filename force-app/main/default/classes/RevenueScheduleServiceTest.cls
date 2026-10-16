@IsTest
private class RevenueScheduleServiceTest {

    private static Deliverable__c makeDeliverable(Decimal unitValue, Integer units, Date recognitionStart) {
        Account a = new Account(Name = 'Test Account Co');
        insert a;
        Opportunity o = new Opportunity(Name = 'Test Program', AccountId = a.Id,
                                        StageName = 'Prospecting', CloseDate = Date.today());
        insert o;
        Project__c p = new Project__c(Name = 'Test Project', Opportunity__c = o.Id, Account__c = a.Id);
        insert p;
        Deliverable__c d = new Deliverable__c(Name = 'Test Deliverable', Project__c = p.Id, Quantity__c = units);
        insert d;
        List<Line_Item__c> lines = new List<Line_Item__c>();
        for (Integer i = 0; i < units; i++) {
            lines.add(new Line_Item__c(Deliverable__c = d.Id, Unit_Value__c = unitValue));
        }
        insert lines;
        // Recognition start is set AFTER the amount roll-up exists; in production a
        // record-triggered flow calls the service — tests call it directly.
        d.Recognition_Start_Date__c = recognitionStart;
        update d;
        return d;
    }

    private static List<Revenue_Schedule__c> schedule(Id deliverableId) {
        return [SELECT Amount__c, Period_Start__c, Period_End__c, Period_Type__c, Recognized_Days__c
                FROM Revenue_Schedule__c WHERE Deliverable__c = :deliverableId ORDER BY Period_Start__c];
    }

    private static Decimal total(List<Revenue_Schedule__c> rows) {
        Decimal t = 0;
        for (Revenue_Schedule__c r : rows) { t += r.Amount__c; }
        return t;
    }

    @IsTest
    static void monthStartProducesTwelveCleanPeriods() {
        Deliverable__c d = makeDeliverable(10000, 3, Date.newInstance(2030, 1, 1));
        Test.startTest();
        RevenueScheduleService.generateForDeliverables(new List<Id>{ d.Id });
        Test.stopTest();

        List<Revenue_Schedule__c> rows = schedule(d.Id);
        System.assertEquals(12, rows.size(), 'a month-start term is 12 full months');
        System.assertEquals(30000, total(rows), 'schedule must sum exactly to the amount');
        for (Revenue_Schedule__c r : rows) {
            System.assertEquals('Full Month', r.Period_Type__c);
        }
    }

    @IsTest
    static void midMonthStartProratesFirstAndFinalPeriods() {
        Deliverable__c d = makeDeliverable(75000, 3, Date.newInstance(2030, 7, 24));
        Test.startTest();
        RevenueScheduleService.generateForDeliverables(new List<Id>{ d.Id });
        Test.stopTest();

        List<Revenue_Schedule__c> rows = schedule(d.Id);
        System.assertEquals(13, rows.size(), 'a mid-month start adds prorated partials at both ends');
        System.assertEquals('First Partial', rows[0].Period_Type__c);
        System.assertEquals('Final Partial', rows[rows.size() - 1].Period_Type__c);
        System.assertEquals(225000, total(rows), 'schedule must sum exactly to the amount');
        System.assertEquals(Date.newInstance(2030, 7, 24), rows[0].Period_Start__c);
        System.assertEquals(Date.newInstance(2031, 7, 23), rows[rows.size() - 1].Period_End__c);
    }

    @IsTest
    static void roundingResidualLandsInFinalPeriod() {
        Deliverable__c d = makeDeliverable(100, 1, Date.newInstance(2030, 1, 1)); // 100 / 12 never divides evenly
        Test.startTest();
        RevenueScheduleService.generateForDeliverables(new List<Id>{ d.Id });
        Test.stopTest();

        List<Revenue_Schedule__c> rows = schedule(d.Id);
        System.assertEquals(100, total(rows), 'exact sum despite rounding');
        Decimal fullMonth = rows[0].Amount__c;
        System.assertNotEquals(fullMonth, rows[rows.size() - 1].Amount__c,
            'the final period absorbs the rounding residual');
    }

    @IsTest
    static void regenerationReplacesTheScheduleAtomically() {
        Deliverable__c d = makeDeliverable(12000, 1, Date.newInstance(2030, 1, 1));
        RevenueScheduleService.generateForDeliverables(new List<Id>{ d.Id });
        System.assertEquals(12, schedule(d.Id).size());

        d.Recognition_Start_Date__c = Date.newInstance(2030, 3, 15);
        update d;
        Test.startTest();
        RevenueScheduleService.generateForDeliverables(new List<Id>{ d.Id });
        Test.stopTest();

        List<Revenue_Schedule__c> rows = schedule(d.Id);
        System.assertEquals(13, rows.size(), 'old rows replaced, new mid-month schedule generated');
        System.assertEquals(12000, total(rows));
    }

    @IsTest
    static void blankDateOrZeroAmountGeneratesNothing() {
        Deliverable__c d = makeDeliverable(0, 1, null);
        Test.startTest();
        RevenueScheduleService.generateForDeliverables(new List<Id>{ d.Id });
        Test.stopTest();
        System.assertEquals(0, schedule(d.Id).size(), 'no date or no amount means no schedule');
    }
}
