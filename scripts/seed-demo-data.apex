// Seeds the end-to-end demo scenario and ASSERTS every figure — the same
// certification scenario the architecture was validated with, on fictional data.
// Run once against a fresh org (setup-demo.sh does it for you). Not self-cleaning:
// the records ARE the demo.

Account acme = new Account(Name = 'Acme Life Sciences', Payment_Terms__c = 'Net 30');
insert acme;

Opportunity deal = new Opportunity(
    Name = 'Acme Provider Insights Program', AccountId = acme.Id,
    StageName = 'Closed Won', CloseDate = Date.today(), Amount = 250500);
insert deal;

Project__c proj = new Project__c(Name = 'Provider Insights Program', Opportunity__c = deal.Id, Account__c = acme.Id);
insert proj;

Deliverable__c workshops = new Deliverable__c(Name = 'Insights Workshops', Project__c = proj.Id, Quantity__c = 3);
Deliverable__c setup = new Deliverable__c(Name = 'Program Setup', Project__c = proj.Id, Quantity__c = 1);
insert new List<Deliverable__c>{ workshops, setup };

List<Line_Item__c> lines = new List<Line_Item__c>{
    new Line_Item__c(Deliverable__c = workshops.Id, Unit_Value__c = 75000, Expected_Invoice_Date__c = Date.today().addDays(7)),
    new Line_Item__c(Deliverable__c = workshops.Id, Unit_Value__c = 75000, Expected_Invoice_Date__c = Date.today().addMonths(2)),
    new Line_Item__c(Deliverable__c = workshops.Id, Unit_Value__c = 75000, Expected_Invoice_Date__c = Date.today().addMonths(4)),
    new Line_Item__c(Deliverable__c = setup.Id, Unit_Value__c = 25500, Expected_Invoice_Date__c = Date.today().addDays(14))
};
insert lines;

// SOW billing plan: milestones reconcile exactly to the $250,500 contract
insert new List<Billing_Milestone__c>{
    new Billing_Milestone__c(Name = 'Invoice on agreement execution', Opportunity__c = deal.Id,
        Expected_Amount__c = 100000, Expected_Date__c = Date.today().addDays(7)),
    new Billing_Milestone__c(Name = 'Invoice after first workshop', Opportunity__c = deal.Id,
        Expected_Amount__c = 75000, Expected_Date__c = Date.today().addMonths(2)),
    new Billing_Milestone__c(Name = 'Invoice on program completion', Opportunity__c = deal.Id,
        Expected_Amount__c = 75500, Expected_Date__c = Date.today().addMonths(6))
};

// Recognition starts today on the workshops -> the engine builds the monthly schedule
workshops.Recognition_Start_Date__c = Date.today();
update workshops;

// One workshop delivered (date auto-stamps, revenue recognizes at line grain)
lines[0].Delivery_Status__c = 'Delivered';
update lines[0];

// Invoice $100k allocated across two lines; $40k collected -> auto Partially Paid
Invoice__c inv = new Invoice__c(Account__c = acme.Id, Opportunity__c = deal.Id,
    Invoice_Amount__c = 100000, Invoice_Date__c = Date.today(), Invoice_Number__c = 'ACME-INV-001');
insert inv;
Invoice_Allocation__c a1 = new Invoice_Allocation__c(Invoice__c = inv.Id, Line_Item__c = lines[0].Id,
    Allocated_Amount__c = 75000, Collected_Amount__c = 0);
Invoice_Allocation__c a2 = new Invoice_Allocation__c(Invoice__c = inv.Id, Line_Item__c = lines[3].Id,
    Allocated_Amount__c = 25000, Collected_Amount__c = 0);
insert new List<Invoice_Allocation__c>{ a1, a2 };
a1.Collected_Amount__c = 40000;
update a1;

// ---- scorecard: every figure must compute exactly ----
Opportunity o = [SELECT Total_Invoiced__c, Total_Paid__c, Total_Recognized__c,
                        Accounts_Receivable__c, Unbilled__c, Deferred_Revenue__c, Remaining_Revenue__c,
                        Billing_Plan_Total__c, Billing_Plan_Mismatch__c
                 FROM Opportunity WHERE Id = :deal.Id];
System.assertEquals(100000, o.Total_Invoiced__c, 'invoiced');
System.assertEquals(40000, o.Total_Paid__c, 'paid');
System.assertEquals(75000, o.Total_Recognized__c, 'recognized (one delivered workshop)');
System.assertEquals(60000, o.Accounts_Receivable__c, 'AR = invoiced - paid');
System.assertEquals(25000, o.Deferred_Revenue__c, 'deferred = invoiced ahead of delivery');
System.assertEquals(0, o.Unbilled__c, 'unbilled');
System.assertEquals(175500, o.Remaining_Revenue__c, 'remaining = contract - recognized');
System.assertEquals(250500, o.Billing_Plan_Total__c, 'billing plan reconciles');
System.assertEquals(false, o.Billing_Plan_Mismatch__c, 'no mismatch flag');

Invoice__c i = [SELECT Status__c, Total_Allocated__c, Total_Collected__c, Unallocated_Amount__c
                FROM Invoice__c WHERE Id = :inv.Id];
System.assertEquals('Partially Paid', i.Status__c, 'auto status');
System.assertEquals(100000, i.Total_Allocated__c);
System.assertEquals(0, i.Unallocated_Amount__c, 'fully allocated');

AggregateResult rs = [SELECT COUNT(Id) c, SUM(Amount__c) s FROM Revenue_Schedule__c
                      WHERE Deliverable__c = :workshops.Id];
System.assert((Integer) rs.get('c') >= 12, 'monthly schedule generated');
System.assertEquals(225000, (Decimal) rs.get('s'), 'schedule sums exactly to the deliverable value');

System.debug('=== DEMO SEED OK: every figure verified ===');
System.debug('Open the "Acme Provider Insights Program" opportunity to explore.');
