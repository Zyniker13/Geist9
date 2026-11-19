// The topical half of the judged corpus (DESIGN 6A, decision 0028): explicit,
// hand-written fake messages grouped by query category. Every judgment in
// qrels.json refers to these stable IDs, so message text here must only be
// edited together with the judgments. All addresses are example.com,
// example.net, example.org; all companies, people, codes and numbers are
// invented.

public struct JudgedMessage: Sendable {
    public var id: String
    public var date: String
    public var from: String
    public var to: String
    public var cc: String?
    public var subject: String
    public var body: String
    public var mailbox: String
    public var attachments: [JudgedAttachment]

    public init(
        _ id: String, _ date: String, _ from: String, _ to: String,
        _ subject: String, _ body: String,
        cc: String? = nil, mailbox: String = "INBOX",
        attachments: [JudgedAttachment] = []
    ) {
        self.id = id
        self.date = date
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.mailbox = mailbox
        self.attachments = attachments
    }
}

public struct JudgedAttachment: Sendable {
    public var filename: String
    public var contentType: String
    public var text: String

    public init(_ filename: String, _ contentType: String, _ text: String) {
        self.filename = filename
        self.contentType = contentType
        self.text = text
    }
}

// MARK: - Category A: Birchline Hardware, one order cycle (j001-j012)

let birchlineMessages: [JudgedMessage] = [
    JudgedMessage(
        "j001", "Wed, 06 Mar 2024 09:12:00 +0000",
        "Birchline Orders <orders@birchline.example.com>", "alice@example.com",
        "Order BX-2214 confirmation",
        "Thanks for your order BX-2214 (industrial fan belt, 4 units). We will email a shipping notice when it leaves the warehouse.",
        attachments: [JudgedAttachment("order-bx-2214.csv", "text/csv",
            "order,part,description,quantity,unit_price\nBX-2214,FB-114,industrial fan belt,4,310.00\n")]
    ),
    JudgedMessage(
        "j002", "Mon, 11 Mar 2024 08:05:00 +0000",
        "Birchline Shipping <shipping@birchline.example.com>", "alice@example.com",
        "Shipment delay on order BX-2214",
        "We are sorry: the fan belt for order BX-2214 is on a shipment delay of five days because the supplier missed a pickup. New dispatch date is March 18.",
    ),
    JudgedMessage(
        "j003", "Wed, 20 Mar 2024 16:40:00 +0000",
        "Birchline Shipping <shipping@birchline.example.com>", "alice@example.com",
        "Delivered: order BX-2214",
        "Order BX-2214 was delivered today and left at the loading dock. Tracking TRK-58213-DE shows the full route.",
    ),
    JudgedMessage(
        "j004", "Thu, 21 Mar 2024 10:00:00 +0000",
        "Birchline Billing <billing@birchline.example.com>", "alice@example.com",
        "Invoice 2024-118 for order BX-2214",
        "Invoice 2024-118 covers order BX-2214: 4 industrial fan belts at 310.00, total 1,240.00, due net-30.",
    ),
    JudgedMessage(
        "j005", "Tue, 02 Apr 2024 11:30:00 +0000",
        "alice@example.com", "billing@birchline.example.com",
        "Invoice dispute: partial shipment",
        "We are opening an invoice dispute for 2024-118. The partial shipment only included 2 fan belts, not the 4 we ordered and paid for.",
    ),
    JudgedMessage(
        "j006", "Thu, 04 Apr 2024 15:22:00 +0000",
        "Birchline Billing <billing@birchline.example.com>", "alice@example.com",
        "Credit memo CM-4471",
        "A credit memo CM-4471 for 620.00 has been issued for the missing fan belts on order BX-2214. It applies to your next invoice.",
    ),
    JudgedMessage(
        "j007", "Mon, 08 Apr 2024 09:45:00 +0000",
        "Birchline Billing <billing@birchline.example.com>", "alice@example.com",
        "Refund processed for CM-4471",
        "The refund for credit memo CM-4471, 620.00, was processed today and should reach your account within five business days.",
    ),
    JudgedMessage(
        "j008", "Tue, 12 Mar 2024 14:10:00 +0000",
        "Birchline Orders <orders@birchline.example.com>", "alice@example.com",
        "Backorder notice: fan belt FB-114",
        "Part FB-114 (industrial fan belt) is on backorder until March 18. Your order BX-2214 keeps its place in the queue.",
    ),
    JudgedMessage(
        "j009", "Fri, 15 Mar 2024 13:00:00 +0000",
        "Birchline Shipping <shipping@birchline.example.com>", "alice@example.com",
        "Partial shipment arrived",
        "The partial shipment with 2 fan belts arrived. The remaining 2 follow once the supplier restocks FB-114.",
    ),
    JudgedMessage(
        "j010", "Wed, 20 Mar 2024 07:55:00 +0000",
        "Birchline Shipping <shipping@birchline.example.com>", "alice@example.com",
        "Out for delivery: TRK-58213-DE",
        "Tracking TRK-58213-DE is out for delivery today, arriving before 18:00. Reference order BX-2214.",
    ),
    JudgedMessage(
        "j011", "Fri, 22 Mar 2024 12:20:00 +0000",
        "alice@example.com", "support@birchline.example.com",
        "Damaged goods claim on BX-2214",
        "Two fan belts from BX-2214 arrived with a damaged box and a torn belt surface. Opening a damaged goods claim; photos attached.",
        attachments: [JudgedAttachment("damage-photos.txt", "text/plain",
            "photo 1: torn belt surface on fan belt unit 2\nphoto 2: crushed box corner, order BX-2214\nphoto 3: pallet label with tracking TRK-58213-DE\n")]
    ),
    JudgedMessage(
        "j012", "Tue, 26 Mar 2024 10:15:00 +0000",
        "Birchline Support <support@birchline.example.com>", "alice@example.com",
        "Replacement shipped for the damaged belts",
        "Your replacement fan belts shipped today on a new order BX-2215, no charge. The damaged units do not need to be returned.",
    ),
]

// MARK: - Category B: Alder & Finch accountants, tax and insurance (j013-j024)

let alderfinchMessages: [JudgedMessage] = [
    JudgedMessage(
        "j013", "Mon, 15 Jan 2024 09:00:00 +0000",
        "Alder & Finch <filing@alderfinch.example.com>", "alice@example.com",
        "Quarterly filing reminder",
        "The quarterly filing for Q4 2023 is due by January 31. Send the sales summary and we will prepare the return.",
    ),
    JudgedMessage(
        "j014", "Wed, 24 Jan 2024 16:30:00 +0000",
        "alice@example.com", "filing@alderfinch.example.com",
        "VAT return draft",
        "Attached is the VAT return draft with the corrected input tax lines for October through December.",
        attachments: [JudgedAttachment("vat-return-draft.csv", "text/csv",
            "period,rate,net,tax\n2023-10,19,8400.00,1596.00\n2023-11,19,9100.00,1729.00\n2023-12,19,7750.00,1472.50\n")]
    ),
    JudgedMessage(
        "j015", "Thu, 25 Jan 2024 08:45:00 +0000",
        "Alder & Finch <filing@alderfinch.example.com>", "alice@example.com",
        "Receipt bundle request",
        "For the audit trail we need the receipt bundle for November and December, sorted by vendor, as one PDF if possible.",
    ),
    JudgedMessage(
        "j016", "Tue, 06 Feb 2024 11:05:00 +0000",
        "Tax Office <notices@taxoffice.example.org>", "alice@example.com",
        "Audit letter: records for 2022",
        "Please provide the records for fiscal year 2022, including the Prüfbericht your accountant prepared, within four weeks.",
    ),
    JudgedMessage(
        "j017", "Mon, 12 Feb 2024 10:40:00 +0000",
        "Alder & Finch <policy@alderfinch.example.com>", "alice@example.com",
        "Expense policy update",
        "The expense policy now caps client dinners at 90 per person and requires the card receipt, not just the summary slip.",
    ),
    JudgedMessage(
        "j018", "Wed, 14 Feb 2024 13:25:00 +0000",
        "Alder & Finch <policy@alderfinch.example.com>", "alice@example.com",
        "Mileage log template",
        "The mileage log template for 2024 is attached. Log every business trip within a week or the deduction is hard to defend.",
        attachments: [JudgedAttachment("mileage-log-2024.csv", "text/csv",
            "date,from,to,km,purpose\n2024-02-05,office,Alder & Finch,34,quarterly filing meeting\n2024-02-07,office,Birchline warehouse,52,damaged goods inspection\n")]
    ),
    JudgedMessage(
        "j019", "Fri, 16 Feb 2024 09:15:00 +0000",
        "Alder & Finch <payroll@alderfinch.example.com>", "alice@example.com",
        "Payroll calendar 2024",
        "The payroll calendar for 2024 is attached. Submission is five days before each pay date; the June date moves because of a holiday.",
        attachments: [JudgedAttachment("payroll-calendar-2024.csv", "text/csv",
            "month,pay_date,submission_deadline\nMarch,2024-03-28,2024-03-23\nApril,2024-04-26,2024-04-21\n")]
    ),
    JudgedMessage(
        "j020", "Mon, 19 Feb 2024 15:50:00 +0000",
        "Nordwind Versicherungen <claims@nordwind.example.org>", "alice@example.com",
        "Schadensbericht zum Wasserrohrbruch",
        "Im Anhang finden Sie den Schadensbericht zum Wasserrohrbruch vom 14. Februar. Die Prüfung dauert etwa zwei Wochen.",
        attachments: [JudgedAttachment("schadensbericht.txt", "text/plain",
            "Schadensbericht: Wasserrohrbruch im Serverraum am 14.02.2024\nUrsache: undichte Lötstelle an der Zuleitung\nGeschätzter Schaden: 4.800 EUR\n")]
    ),
    JudgedMessage(
        "j021", "Wed, 21 Feb 2024 10:20:00 +0000",
        "alice@example.com", "claims@nordwind.example.org",
        "Ergänzung zur Schadensmeldung",
        "Anbei die ergänzende Schadensmeldung mit den Handwerkerrechnungen vom 19. und 20. Februar.",
        attachments: [JudgedAttachment("handwerkerrechnungen.txt", "text/plain",
            "Handwerkerrechnung 19.02.: Trockenlegung 620 EUR\nHandwerkerrechnung 20.02.: Neue Zuleitung 1.140 EUR\n")]
    ),
    JudgedMessage(
        "j022", "Fri, 01 Mar 2024 14:35:00 +0000",
        "Nordwind Versicherungen <claims@nordwind.example.org>", "alice@example.com",
        "Versicherung: Regulierung läuft",
        "Die Regulierung Ihres Schadenfalls läuft. Nach Abschluss des Schadensberichts folgt die Zahlung innerhalb von zehn Werktagen.",
    ),
    JudgedMessage(
        "j023", "Mon, 04 Mar 2024 08:30:00 +0000",
        "Alder & Finch <filing@alderfinch.example.com>", "alice@example.com",
        "Accounting cutoff dates",
        "Accounting cutoff for March is the 28th. Invoices dated after the cutoff belong to the April books.",
    ),
    JudgedMessage(
        "j024", "Tue, 19 Mar 2024 17:05:00 +0000",
        "Alder & Finch <filing@alderfinch.example.com>", "alice@example.com",
        "Year-end closing checklist",
        "The year-end closing checklist is attached. The Jahresabschluss meeting is set for April 9 at 10:00.",
        attachments: [JudgedAttachment("closing-checklist.txt", "text/plain",
            "year-end closing checklist:\n1. bank reconciliation\n2. fixed asset register\n3. Jahresabschluss draft for the April 9 meeting\n4. depreciation schedule\n")]
    ),
]

// MARK: - Category C: Cedar Run Software, licensing and contracts (j025-j034)

let cedarrunMessages: [JudgedMessage] = [
    JudgedMessage(
        "j025", "Tue, 09 Jan 2024 10:10:00 +0000",
        "Cedar Run Sales <sales@cedarrun.example.com>", "alice@example.com",
        "License renewal quote for 2024",
        "The license renewal quote for 2024 is 18 seats at 1,150.00 each. Multi-year terms get a 15 percent discount.",
    ),
    JudgedMessage(
        "j026", "Thu, 11 Jan 2024 15:45:00 +0000",
        "alice@example.com", "sales@cedarrun.example.com",
        "Contract redlines attached",
        "Attached are our contract redlines. The liability cap and the data residency clause are the two points we need changed.",
        attachments: [JudgedAttachment("contract-redlines.txt", "text/plain",
            "redline 1: liability cap raised to 24 months of fees\nredline 2: data residency limited to EU regions\nredline 3: termination notice shortened to 30 days\n")]
    ),
    JudgedMessage(
        "j027", "Mon, 15 Jan 2024 09:55:00 +0000",
        "Cedar Run Legal <legal@cedarrun.example.com>", "alice@example.com",
        "NDA draft for the pilot",
        "The NDA draft for the pilot is ready. It covers the evaluation data only and expires after the pilot ends.",
    ),
    JudgedMessage(
        "j028", "Wed, 17 Jan 2024 14:00:00 +0000",
        "alice@example.com", "sales@cedarrun.example.com",
        "Purchase order PO-8841",
        "Purchase order PO-8841 for the license renewal is in your portal. The reference must appear on the invoice.",
    ),
    JudgedMessage(
        "j029", "Fri, 19 Jan 2024 11:20:00 +0000",
        "Cedar Run Sales <sales@cedarrun.example.com>", "alice@example.com",
        "Renewal discount applied",
        "We applied the renewal discount: 15 percent off the three-year term, for a total of 44,085.00 instead of 51,865.00.",
    ),
    JudgedMessage(
        "j030", "Mon, 22 Jan 2024 16:05:00 +0000",
        "Cedar Run Support <support@cedarrun.example.com>", "alice@example.com",
        "Trial extension granted",
        "The trial extension runs until February 29. All evaluation data stays in place; nothing needs to be migrated.",
    ),
    JudgedMessage(
        "j031", "Wed, 24 Jan 2024 09:40:00 +0000",
        "alice@example.com", "sales@cedarrun.example.com",
        "Seat expansion to 26",
        "We need a seat expansion from 18 to 26 users for the support team before the renewal start date.",
    ),
    JudgedMessage(
        "j032", "Tue, 30 Jan 2024 12:30:00 +0000",
        "Cedar Run Billing <billing@cedarrun.example.com>", "alice@example.com",
        "Invoice 2024-0042, net-30",
        "Invoice 2024-0042 for the adjusted renewal, 47,510.00, is due net-30 and carries the PO-8841 reference.",
    ),
    JudgedMessage(
        "j033", "Mon, 05 Feb 2024 10:50:00 +0000",
        "Cedar Run Billing <billing@cedarrun.example.com>", "alice@example.com",
        "Payment received, thank you",
        "Payment for invoice 2024-0042 was received on February 3. The license counts update overnight.",
    ),
    JudgedMessage(
        "j034", "Thu, 08 Feb 2024 13:15:00 +0000",
        "alice@example.com", "legal@cedarrun.example.com",
        "Termination clause question",
        "Before signing: does the termination clause allow exit for a data breach without the 60-day wind-down?",
    ),
]

// MARK: - Category D: Northgate Consulting, hiring and onboarding (j035-j044)

let northgateMessages: [JudgedMessage] = [
    JudgedMessage(
        "j035", "Mon, 05 Feb 2024 09:30:00 +0000",
        "Northgate People <people@northgate.example.com>", "alice@example.com",
        "Offer letter for Maya Lindqvist",
        "The offer letter for Maya Lindqvist, senior analyst, is attached. Start date is March 1, salary band C2.",
        attachments: [JudgedAttachment("offer-letter.txt", "text/plain",
            "offer letter: Maya Lindqvist, senior analyst, start March 1, band C2\n")]
    ),
    JudgedMessage(
        "j036", "Wed, 07 Feb 2024 11:45:00 +0000",
        "Northgate People <people@northgate.example.com>", "alice@example.com",
        "Onboarding checklist",
        "The onboarding checklist covers the first two weeks: equipment, accounts, security training, and the buddy pairing.",
        attachments: [JudgedAttachment("onboarding-checklist.txt", "text/plain",
            "onboarding checklist:\nday 1: accounts and laptop\nday 2: security training\nday 3: buddy pairing with Tomas\nday 10: first solo task\n")]
    ),
    JudgedMessage(
        "j037", "Thu, 08 Feb 2024 14:20:00 +0000",
        "Northgate IT <it@northgate.example.com>", "alice@example.com",
        "Laptop provisioning for the new hire",
        "Laptop provisioning for Maya is done: 16-inch unit, dock, and the VPN profile preinstalled.",
    ),
    JudgedMessage(
        "j038", "Fri, 09 Feb 2024 08:55:00 +0000",
        "Northgate People <people@northgate.example.com>", "alice@example.com",
        "Badge photo before day one",
        "Please send a badge photo for Maya before day one so reception can print the card.",
    ),
    JudgedMessage(
        "j039", "Mon, 12 Feb 2024 10:05:00 +0000",
        "Northgate People <people@northgate.example.com>", "alice@example.com",
        "First-week schedule",
        "The first-week schedule is attached: three intro meetings, one shadowing day, and the team lunch on Thursday.",
        attachments: [JudgedAttachment("first-week.txt", "text/plain",
            "first-week schedule:\nMon: welcome and accounts\nTue: intro meetings\nWed: shadowing day\nThu: team lunch\nFri: first solo task\n")]
    ),
    JudgedMessage(
        "j040", "Tue, 13 Feb 2024 15:30:00 +0000",
        "Northgate People <people@northgate.example.com>", "alice@example.com",
        "Benefits enrollment window",
        "The benefits enrollment window for the new hire opens on the start date and stays open for 30 days.",
    ),
    JudgedMessage(
        "j041", "Wed, 14 Feb 2024 09:25:00 +0000",
        "Northgate Office <office@northgate.example.com>", "alice@example.com",
        "Parking permit for the new analyst",
        "The parking permit for the underground deck is ready; it activates on March 1 with the badge.",
    ),
    JudgedMessage(
        "j042", "Thu, 15 Feb 2024 16:40:00 +0000",
        "Northgate People <people@northgate.example.com>", "alice@example.com",
        "Mentor assignment confirmed",
        "Tomas Herrera confirmed as mentor. First mentoring session is scheduled for the second week.",
    ),
    JudgedMessage(
        "j043", "Fri, 16 Feb 2024 12:10:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Team intro: Maya Lindqvist joins March 1",
        "Short intro: Maya Lindqvist joins the analytics group on March 1. She comes from a logistics data team and will take over the demand reports.",
    ),
    JudgedMessage(
        "j044", "Mon, 19 Feb 2024 09:50:00 +0000",
        "alice@example.com", "people@northgate.example.com",
        "Offsite planning for the spring offsite",
        "Two venue options for the spring offsite: the lakeside house with 12 beds, or two connected rooms at the mountain lodge. Votes by Friday.",
    ),
]

// MARK: - Category E: Lakeview Apartments, the heater thread (j045-j052)

let lakeviewMessages: [JudgedMessage] = [
    JudgedMessage(
        "j045", "Mon, 22 Jan 2024 18:05:00 +0000",
        "alice@example.com", "management@lakeview.example.com",
        "Heater in unit 4 stopped working",
        "The heater in unit 4 stopped working last night. The thermostat reads 15 degrees at 6 am. Can someone take a look this week?",
    ),
    JudgedMessage(
        "j046", "Tue, 23 Jan 2024 10:30:00 +0000",
        "Lakeview Management <management@lakeview.example.com>", "alice@example.com",
        "Re: heater in unit 4",
        "Thanks for flagging. We checked with the property owner and the landlord agreed to fix the heater: a technician comes Thursday between 9 and 12.",
    ),
    JudgedMessage(
        "j047", "Wed, 24 Jan 2024 09:15:00 +0000",
        "Lakeview Management <management@lakeview.example.com>", "alice@example.com",
        "Repair visit confirmation",
        "Confirming the repair visit for Thursday, January 25, 9-12. The technician will need access to the utility closet.",
    ),
    JudgedMessage(
        "j048", "Fri, 26 Jan 2024 19:40:00 +0000",
        "alice@example.com", "management@lakeview.example.com",
        "Still cold after the visit",
        "The visit happened but the heater is still cold. The technician mentioned a replacement part arriving Monday.",
    ),
    JudgedMessage(
        "j049", "Sat, 27 Jan 2024 11:20:00 +0000",
        "alice@example.com", "management@lakeview.example.com",
        "Radiator works, heater does not",
        "For clarity: the bedroom radiator works fine, it is only the living room heater that is broken.",
    ),
    JudgedMessage(
        "j050", "Mon, 05 Feb 2024 08:00:00 +0000",
        "Lakeview Management <billing@lakeview.example.com>", "alice@example.com",
        "Rent receipt for February",
        "The rent receipt for February is attached for your records.",
        attachments: [JudgedAttachment("rent-receipt-february.txt", "text/plain",
            "rent receipt February: unit 4, 1,180.00, received February 3\n")]
    ),
    JudgedMessage(
        "j051", "Tue, 20 Feb 2024 14:45:00 +0000",
        "Lakeview Management <management@lakeview.example.com>", "alice@example.com",
        "Lease renewal terms",
        "The lease renewal adds 3 percent, keeps the parking spot, and extends to February 2025.",
    ),
    JudgedMessage(
        "j052", "Wed, 21 Feb 2024 10:55:00 +0000",
        "alice@example.com", "management@lakeview.example.com",
        "Parking space swap request",
        "The neighbor offered a parking space swap to the covered row; asking if the assignment is transferable.",
    ),
]

// MARK: - Category F: Norvair travel (j053-j060)

let norvairMessages: [JudgedMessage] = [
    JudgedMessage(
        "j053", "Thu, 15 Feb 2024 17:25:00 +0000",
        "Norvair Booking <booking@norvair.example.com>", "alice@example.com",
        "Booking NX4KQW confirmed",
        "Booking NX4KQW is confirmed: outbound March 4, return March 9, seat 14A, one checked bag.",
    ),
    JudgedMessage(
        "j054", "Thu, 15 Feb 2024 17:30:00 +0000",
        "Norvair Booking <booking@norvair.example.com>", "alice@example.com",
        "Your itinerary",
        "The full itinerary is attached as a web page for offline reading.",
        attachments: [JudgedAttachment("itinerary.html", "text/html",
            "<h1>Itinerary NX4KQW</h1><p>Outbound March 4, gate opens 5:40, return March 9. Hotel: Harbor View, two nights pre-booked.</p>")]
    ),
    JudgedMessage(
        "j055", "Sun, 25 Feb 2024 20:15:00 +0000",
        "Norvair Operations <ops@norvair.example.com>", "alice@example.com",
        "Flight cancelled: NA204 on March 4",
        "Flight NA204 on March 4 is cancelled due to the airport closure. Options: rebooking to the 5th at 7:10 or a full refund.",
    ),
    JudgedMessage(
        "j056", "Mon, 26 Feb 2024 09:50:00 +0000",
        "Norvair Booking <booking@norvair.example.com>", "alice@example.com",
        "Rebooking confirmed to March 5",
        "Rebooking confirmed: NA207 on March 5 at 7:10, same seat 14A, booking NX4KQW unchanged.",
    ),
    JudgedMessage(
        "j057", "Tue, 27 Feb 2024 13:35:00 +0000",
        "Norvair Support <support@norvair.example.com>", "alice@example.com",
        "Refund timeline for the cancelled leg",
        "If you keep the rebooking, the refund for the cancelled leg is not applicable. If you cancel, the refund takes 7-10 business days.",
    ),
    JudgedMessage(
        "j058", "Mon, 04 Mar 2024 15:00:00 +0000",
        "Norvair Operations <ops@norvair.example.com>", "alice@example.com",
        "Hotel voucher for the rebooked night",
        "Because the rebooking moved you a day, a hotel voucher for the night of March 4 at Harbor View is attached.",
        attachments: [JudgedAttachment("hotel-voucher.txt", "text/plain",
            "hotel voucher: Harbor View, night of March 4, room 512, code HV-90211\n")]
    ),
    JudgedMessage(
        "j059", "Tue, 05 Mar 2024 08:20:00 +0000",
        "Norvair Lounge <lounge@norvair.example.com>", "alice@example.com",
        "Meal allowance during the delay",
        "The gate delay qualifies you for the meal allowance: 18.00 at any terminal restaurant, add it to the room bill or claim it back.",
    ),
    JudgedMessage(
        "j060", "Wed, 06 Mar 2024 12:45:00 +0000",
        "Norvair Booking <booking@norvair.example.com>", "alice@example.com",
        "Seat upgrade offer for the return",
        "An upgrade offer for the return leg is open until check-in: row 2 window, 89.00, booking NX4KQW.",
    ),
]
