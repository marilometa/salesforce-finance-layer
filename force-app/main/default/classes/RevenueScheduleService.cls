/**
 * Generates monthly revenue recognition schedules for Deliverables.
 *
 * Model: straight-line over 12 months from Recognition_Start_Date__c at a daily
 * period rate. A mid-month start produces day-prorated partial first and final
 * periods (13 rows); a month-start produces 12 clean rows. Rounding differences
 * land in the final period, so the schedule ALWAYS sums exactly to the
 * deliverable's Amount__c. Regeneration is idempotent: existing schedule rows
 * for the deliverable are replaced atomically.
 *
 * Invoked from a record-triggered flow when Recognition_Start_Date__c is set
 * or changed. Kept in Apex deliberately: exact-sum guarantees with per-day
 * proration need iteration and rounding control Flow cannot express cleanly.
 */
public with sharing class RevenueScheduleService {
    private static final Integer TERM_MONTHS = 12;

    @InvocableMethod(
        label='Generate Revenue Schedule'
        description='Rebuilds the monthly recognition schedule for the given deliverables.'
    )
    public static void generate(List<Id> deliverableIds) {
        generateForDeliverables(deliverableIds);
    }

    public static List<Revenue_Schedule__c> generateForDeliverables(List<Id> deliverableIds) {
        List<Deliverable__c> deliverables = [
            SELECT Id, Amount__c, Recognition_Start_Date__c
            FROM Deliverable__c
            WHERE Id IN :deliverableIds
        ];

        delete [SELECT Id FROM Revenue_Schedule__c WHERE Deliverable__c IN :deliverableIds];

        List<Revenue_Schedule__c> rows = new List<Revenue_Schedule__c>();
        for (Deliverable__c d : deliverables) {
            if (d.Recognition_Start_Date__c == null || d.Amount__c == null || d.Amount__c == 0) {
                continue;
            }
            rows.addAll(buildSchedule(d));
        }
        insert rows;
        return rows;
    }

    private static List<Revenue_Schedule__c> buildSchedule(Deliverable__c d) {
        Date termStart = d.Recognition_Start_Date__c;
        Date termEnd = termStart.addMonths(TERM_MONTHS).addDays(-1);
        Integer totalDays = termStart.daysBetween(termEnd) + 1;
        Decimal total = d.Amount__c;

        List<Revenue_Schedule__c> rows = new List<Revenue_Schedule__c>();
        Date cursor = termStart;
        Decimal allocated = 0;

        while (cursor <= termEnd) {
            Date monthStart = cursor.toStartOfMonth();
            Date monthEnd = monthStart.addMonths(1).addDays(-1);
            Date periodStart = cursor;
            Date periodEnd = monthEnd < termEnd ? monthEnd : termEnd;
            Integer periodDays = periodStart.daysBetween(periodEnd) + 1;
            Boolean isFinal = periodEnd == termEnd;

            Decimal amount = isFinal
                ? total - allocated // remainder lands in the final period: exact sum
                : (total * periodDays / totalDays).setScale(2, RoundingMode.HALF_UP);
            allocated += amount;

            String periodType = 'Full Month';
            if (periodStart != monthStart) {
                periodType = 'First Partial';
            } else if (isFinal && periodEnd != monthEnd) {
                periodType = 'Final Partial';
            }

            rows.add(new Revenue_Schedule__c(
                Deliverable__c = d.Id,
                Amount__c = amount,
                Period_Start__c = periodStart,
                Period_End__c = periodEnd,
                Recognition_Month__c = monthStart,
                Period_Type__c = periodType,
                Recognized_Days__c = periodDays
            ));
            cursor = periodEnd.addDays(1);
        }
        return rows;
    }
}
