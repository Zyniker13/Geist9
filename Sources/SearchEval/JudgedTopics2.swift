// The topical half of the judged corpus, part two (DESIGN 6A, decision 0028):
// multilingual fixtures, diacritics, names and address tokens, dated messages,
// phrase traps, attachment-only text, and trigram substring fixtures. Same
// rules as part one: stable IDs, fake entities only, edit together with
// qrels.json.

// MARK: - Category G: Multilingual fixtures (j061-j080)

let multilingualMessages: [JudgedMessage] = [
    JudgedMessage(
        "j061", "Thu, 11 Jan 2024 10:05:00 +0000",
        "Nordwind GmbH <buchhaltung@nordwind.example.org>", "alice@example.com",
        "Rechnung 2024-301",
        "Anbei Rechnung 2024-301 über 3.250,00 EUR für die Wartung im Januar. Fällig in 14 Tagen.",
    ),
    JudgedMessage(
        "j062", "Mon, 15 Jan 2024 09:40:00 +0000",
        "alice@example.com", "buchhaltung@nordwind.example.org",
        "Laufende Rechnungen im Überblick",
        "Die Übersicht der laufenden Rechnungen nach Januar: Nordwind 3.250,00, Cedar Run 47.510,00.",
    ),
    JudgedMessage(
        "j063", "Wed, 17 Jan 2024 14:25:00 +0000",
        "alice@example.com", "filing@alderfinch.example.com",
        "Rechnungen für Q3 gesammelt",
        "Alle Rechnungen für Q3 liegen im gemeinsamen Ordner; die Summe passt zum Vorjahr.",
    ),
    JudgedMessage(
        "j064", "Tue, 23 Jan 2024 08:55:00 +0000",
        "Nordwind GmbH <buchhaltung@nordwind.example.org>", "alice@example.com",
        "Mahnung: überfällige Rechnung 2023-214",
        "Leider ist Rechnung 2023-214 überfällig. Bei Zahlung bis Freitag entfällt die Mahngebühr.",
    ),
    JudgedMessage(
        "j065", "Thu, 25 Jan 2024 16:15:00 +0000",
        "alice@example.com", "filing@alderfinch.example.com",
        "Jahresabschluss 2023 fertig gestellt",
        "Der Jahresabschluss 2023 ist fertig gestellt und geht mit dem Prüfbericht an die Bank.",
    ),
    JudgedMessage(
        "j066", "Fri, 09 Feb 2024 11:30:00 +0000",
        "Birchline DK <faktura@birchline.example.com>", "alice@example.com",
        "Faktura for februar",
        "Vi har modtaget fakturaen for februar og sender den videre til budget ansvarlige i afdelingen.",
    ),
    JudgedMessage(
        "j067", "Mon, 12 Feb 2024 09:20:00 +0000",
        "Nordic Supply <order@nordicsupply.example.com>", "alice@example.com",
        "Faktura nr 8811",
        "Faktura nr 8811 för februari leveransen, betalas via autogiro som vanligt.",
    ),
    JudgedMessage(
        "j068", "Tue, 13 Feb 2024 10:45:00 +0000",
        "Veluwe Trading <facturatie@veluwe.example.org>", "alice@example.com",
        "Factuur februari",
        "De factuur voor februari is verzonden; betaling binnen 30 dagen via de gebruikelijke rekening.",
    ),
    JudgedMessage(
        "j069", "Wed, 14 Feb 2024 09:35:00 +0000",
        "Douro Insumos <faturacao@douro.example.org>", "alice@example.com",
        "Fatura de fevereiro",
        "A fatura de fevereiro segue em anexo, com os mesmos itens do contrato anual.",
        attachments: [JudgedAttachment("fatura-fevereiro.txt", "text/plain",
            "Fatura fevereiro: manutenção anual, 1.980,00 EUR, vencimento 14 dias\n")]
    ),
    JudgedMessage(
        "j070", "Thu, 15 Feb 2024 15:10:00 +0000",
        "Mesa Group <admin@mesa.example.org>", "alice@example.com",
        "Factura y reunión",
        "La factura de febrero va en el sobre habitual. La reunión de coordinación pasa al jueves a las 16.",
    ),
    JudgedMessage(
        "j071", "Fri, 16 Feb 2024 08:50:00 +0000",
        "Loire Conseil <compta@loire.example.org>", "alice@example.com",
        "Facture et contrat",
        "La facture de janvier est réglée. Le contrat annuel attend seulement votre signature.",
    ),
    JudgedMessage(
        "j072", "Mon, 19 Feb 2024 13:05:00 +0000",
        "Po Software <amministrazione@po.example.org>", "alice@example.com",
        "Fattura n. 2024/07",
        "La fattura n. 2024/07 per la manutenzione è emessa; scadenza a 30 giorni come da contratto.",
    ),
    JudgedMessage(
        "j073", "Tue, 20 Feb 2024 10:15:00 +0000",
        "Analytika <reports@analytika.example.org>", "alice@example.com",
        "Отчёт за март",
        "Отчёт за март готов: рост заявок на 12 процентов, узкие места в обработке платежей.",
    ),
    JudgedMessage(
        "j074", "Wed, 21 Feb 2024 11:40:00 +0000",
        "Hostline <billing@hostline.example.org>", "alice@example.com",
        "Счёт за хостинг",
        "Счёт за хостинг за февраль выставлен, оплата до 5 марта, как обычно по реквизитам из договора.",
    ),
    JudgedMessage(
        "j075", "Thu, 22 Feb 2024 09:30:00 +0000",
        "Analytika <team@analytika.example.org>", "alice@example.com",
        "Встреча в пятницу",
        "Встреча в пятницу в 15:00, повестка: отчёт за февраль и план на квартал.",
    ),
    JudgedMessage(
        "j076", "Fri, 23 Feb 2024 10:20:00 +0000",
        "Kaitaku Ltd <seikyu@kaitaku.example.org>", "alice@example.com",
        "請求書送付のお知らせ",
        "1月分の請求書を添付いたします。支払期日は2月末です。よろしくお願いいたします。",
        attachments: [JudgedAttachment("seikyu-2024-01.txt", "text/plain",
            "請求書 2024-01: ライセンス更新 250,000円 支払期日 2月末\n")]
    ),
    JudgedMessage(
        "j077", "Mon, 26 Feb 2024 14:45:00 +0000",
        "Kaitaku Ltd <team@kaitaku.example.org>", "alice@example.com",
        "来週の会議について",
        "来週の会議は火曜10時に変更になりました。議事録担当は佐藤さんです。",
    ),
    JudgedMessage(
        "j078", "Tue, 27 Feb 2024 09:55:00 +0000",
        "Project Room <pm@projectroom.example.org>", "alice@example.com",
        "二月会议纪要",
        "二月会议纪要已归档：发布日期定为三月十二日，风险清单更新了两项。",
        attachments: [JudgedAttachment("meeting-notes.txt", "text/plain",
            "会议纪要：发布日期三月十二日；风险清单更新两项；测试负责人待定\n")]
    ),
    JudgedMessage(
        "j079", "Wed, 28 Feb 2024 16:30:00 +0000",
        "Lumen Store <order@lumen.example.org>", "alice@example.com",
        "发票已收到",
        "发票已收到并登记入账，款项将在付款周期内支付。",
    ),
    JudgedMessage(
        "j080", "Thu, 29 Feb 2024 11:10:00 +0000",
        "Hanok Labs <admin@hanok.example.org>", "alice@example.com",
        "회의록 및 결제 확인",
        "지난 회의록을 공유했습니다. 결제 확인 메일도 별도로 발송되었습니다.",
    ),
]

// MARK: - Category H: Folding and diacritics (j081-j090)

let foldingMessages: [JudgedMessage] = [
    JudgedMessage(
        "j081", "Mon, 12 Feb 2024 12:30:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Café meeting",
        "Let us do the review at the café on the corner; their back room is quiet before 11.",
    ),
    JudgedMessage(
        "j082", "Tue, 13 Feb 2024 09:15:00 +0000",
        "Candidate <candidate@example.org>", "people@northgate.example.com",
        "Application with résumé attached",
        "Attached is my résumé for the analyst opening. I can talk any afternoon this week.",
        attachments: [JudgedAttachment("resume-cv.txt", "text/plain",
            "résumé: five years demand planning, warehouse analytics, SQL and Python\n")]
    ),
    JudgedMessage(
        "j083", "Wed, 14 Feb 2024 15:45:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Retrospective notes",
        "Calling our first approach naïve is fair; the second one handled the edge cases.",
    ),
    JudgedMessage(
        "j084", "Thu, 15 Feb 2024 18:20:00 +0000",
        "Lena Fischer <lena@example.org>", "alice@example.com",
        "Grüße aus Hamburg",
        "Viele Grüße aus Hamburg, das Wochenende war zu kurz. Nächstes Mal bringe ich die Fotos mit.",
    ),
    JudgedMessage(
        "j085", "Fri, 16 Feb 2024 08:05:00 +0000",
        "City Works <works@city.example.org>", "residents@example.org",
        "Straße gesperrt",
        "Die Straße bleibt bis Donnerstag gesperrt; die Zufahrt zum Hinterhof ist frei.",
    ),
    JudgedMessage(
        "j086", "Mon, 19 Feb 2024 10:40:00 +0000",
        "Ingrid Sørensen <ingrid@example.org>", "alice@example.com",
        "Sørensen travel plans",
        "Ingrid Sørensen here, confirming the site visit on the 27th and the dinner after.",
    ),
    JudgedMessage(
        "j087", "Tue, 20 Feb 2024 13:55:00 +0000",
        "Harbor Ferries <booking@harborf.example.org>", "alice@example.com",
        "Fähre gebucht",
        "Die Fähre für den 24. ist gebucht, Abfahrt 9:40, Rückfahrt offen.",
    ),
    JudgedMessage(
        "j088", "Wed, 21 Feb 2024 09:25:00 +0000",
        "Cedaroft Wares <catalog@cedaroft.example.com>", "alice@example.com",
        "Catalog update",
        "The new catalog went out; the full-width test line follows: Ｃｅｄａｒｏｆｔ catalog spring edition.",
    ),
    JudgedMessage(
        "j089", "Thu, 22 Feb 2024 14:35:00 +0000",
        "alice@example.com", "people@northgate.example.com",
        "Resume review panel",
        "The resume review panel meets Friday; bring the shortlist and one written note per candidate.",
    ),
    JudgedMessage(
        "j090", "Fri, 23 Feb 2024 08:50:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Föhn weather warning",
        "With the Föhn coming, expect the mountain leg of the offsite route to be slow; leave an hour early.",
    ),
]

// MARK: - Category I: Names and address tokens (j091-j100)

let namesMessages: [JudgedMessage] = [
    JudgedMessage(
        "j091", "Mon, 05 Feb 2024 10:20:00 +0000",
        "Jane Doe <jane.doe@example.net>", "alice@example.com",
        "Purchase order question",
        "Quick question on purchase order PO-8841: should the site reference appear on every line item?",
    ),
    JudgedMessage(
        "j092", "Tue, 06 Feb 2024 09:05:00 +0000",
        "alice@example.com", "jane.doe@example.net",
        "Re: Purchase order question",
        "Yes: every line item carries the site reference, otherwise the receiving dock rejects the delivery.",
    ),
    JudgedMessage(
        "j093", "Wed, 07 Feb 2024 11:50:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Welcome Priya Natarajan",
        "Priya Natarajan joins the data practice as principal; she will lead the retail analytics account.",
    ),
    JudgedMessage(
        "j094", "Thu, 08 Feb 2024 15:35:00 +0000",
        "Priya Natarajan <priya.natarajan@northgate.example.com>", "alice@example.com",
        "Retail analytics kickoff",
        "Kicking off the retail analytics account next week; I will send an agenda by Monday.",
        cc: "alice@example.com"
    ),
    JudgedMessage(
        "j095", "Fri, 09 Feb 2024 08:45:00 +0000",
        "Marcus Webb <marcus.webb@example.net>", "alice@example.com",
        "Warehouse audit follow-up",
        "Following up on the warehouse audit: two findings are closed, the pallet scan backlog needs a plan.",
    ),
    JudgedMessage(
        "j096", "Mon, 12 Feb 2024 10:55:00 +0000",
        "Tomas Herrera <tomas.herrera@example.net>", "alice@example.com",
        "Demand report draft",
        "The demand report draft is in the shared folder; comments by Wednesday please.",
    ),
    JudgedMessage(
        "j097", "Tue, 13 Feb 2024 12:40:00 +0000",
        "Ingrid Sørensen <ingrid@example.org>", "alice@example.com",
        "Site visit logistics",
        "For the site visit: Ingrid Sørensen arrives 10:30, plant tour first, then the sample review.",
    ),
    JudgedMessage(
        "j098", "Wed, 14 Feb 2024 09:30:00 +0000",
        "Kenji Yamamoto <kenji.yamamoto@example.org>", "alice@example.com",
        "Vendor scorecard",
        "The vendor scorecard for the quarter is ready; Kenji Yamamoto will present it at the review.",
    ),
    JudgedMessage(
        "j099", "Thu, 15 Feb 2024 16:20:00 +0000",
        "Sofia Petrova <sofia.petrova@example.net>", "alice@example.com",
        "Translation schedule",
        "The translation schedule holds; Sofia Petrova flagged two strings that need context before Friday.",
    ),
    JudgedMessage(
        "j100", "Fri, 16 Feb 2024 11:15:00 +0000",
        "Ana Duarte <ana.duarte@example.org>", "alice@example.com",
        "Onboarding buddy handover",
        "Ana Duarte takes over as onboarding buddy from next week; everything is documented in the checklist.",
    ),
]

// MARK: - Category J: Dated messages (j101-j110)

let datedMessages: [JudgedMessage] = [
    JudgedMessage(
        "j101", "Mon, 15 Mar 2021 08:00:00 +0000",
        "Hostline Ops <ops@hostline.example.org>", "alice@example.com",
        "Server maintenance window",
        "The server maintenance window runs tonight from 22:00 to 02:00; expect brief API pauses.",
    ),
    JudgedMessage(
        "j102", "Tue, 05 Nov 2019 17:30:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Outage postmortem",
        "The outage postmortem is written: the cache stampede was the root cause, the fix shipped yesterday.",
    ),
    JudgedMessage(
        "j103", "Wed, 12 Feb 2020 09:40:00 +0000",
        "Tax Office <notices@taxoffice.example.org>", "alice@example.com",
        "Tax receipt for 2019",
        "Your tax receipt for the 2019 assessment is enclosed; keep it with the year-end records.",
    ),
    JudgedMessage(
        "j104", "Wed, 01 Jun 2022 10:05:00 +0000",
        "Cedar Run Legal <legal@cedarrun.example.com>", "alice@example.com",
        "Contract signed",
        "The contract for the analytics platform was signed today; countersigned copy attached.",
        attachments: [JudgedAttachment("signed-contract.txt", "text/plain",
            "signed contract: analytics platform, three-year term, effective June 1, 2022\n")]
    ),
    JudgedMessage(
        "j105", "Thu, 30 Nov 2023 18:15:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Launch retro",
        "Launch retro notes: the feature flag cleanup saved us twice; write it into the runbook.",
    ),
    JudgedMessage(
        "j106", "Fri, 03 Dec 2021 12:00:00 +0000",
        "Norvair Booking <booking@norvair.example.com>", "alice@example.com",
        "December itinerary change",
        "Your December itinerary changed: the return moves to the 21st, same flight number.",
    ),
    JudgedMessage(
        "j107", "Sat, 04 Jan 2020 09:20:00 +0000",
        "Lakeview Management <management@lakeview.example.com>", "alice@example.com",
        "Water meter reading",
        "The water meter reading happens January 9; someone must be home between 8 and 12.",
    ),
    JudgedMessage(
        "j108", "Sun, 16 Jun 2024 20:45:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Quarterly numbers ready",
        "The quarterly numbers are ready early this time; review tomorrow morning before the board call.",
    ),
    JudgedMessage(
        "j109", "Mon, 17 Jun 2024 07:55:00 +0000",
        "Birchline Orders <orders@birchline.example.com>", "alice@example.com",
        "Order BX-2216 confirmation",
        "Order BX-2216 (two pressure gauges) is confirmed; ships within a week.",
    ),
    JudgedMessage(
        "j110", "Tue, 18 Jun 2024 14:35:00 +0000",
        "Northgate IT <it@northgate.example.com>", "alice@example.com",
        "VPN certificate renewal",
        "The VPN certificate renews tonight; re-authenticate in the morning.",
    ),
]

// MARK: - Category K: Phrase queries and adjacency traps (j111-j125)

let phraseMessages: [JudgedMessage] = [
    JudgedMessage(
        "j111", "Mon, 19 Feb 2024 09:30:00 +0000",
        "alice@example.com", "filing@alderfinch.example.com",
        "Budget review prep",
        "For the budget review, pull the trailing twelve months by cost center.",
    ),
    JudgedMessage(
        "j112", "Tue, 20 Feb 2024 10:40:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Review of the budget process",
        "We will review the budget process itself at the March meeting; bring pain points.",
    ),
    JudgedMessage(
        "j113", "Wed, 21 Feb 2024 11:55:00 +0000",
        "Birchline Shipping <shipping@birchline.example.com>", "alice@example.com",
        "Shipment delay notice",
        "A shipment delay of two days hit the March consignment; the dock slot moves accordingly.",
    ),
    JudgedMessage(
        "j114", "Thu, 22 Feb 2024 12:05:00 +0000",
        "alice@example.com", "ops@northgate.example.com",
        "Delay in shipment of the sensors",
        "There is a delay in shipment of the sensors; the vendor blames the customs form.",
    ),
    JudgedMessage(
        "j115", "Fri, 23 Feb 2024 09:25:00 +0000",
        "Cedar Run Legal <legal@cedarrun.example.com>", "alice@example.com",
        "Service level agreement draft",
        "The service level agreement draft now caps response time at four business hours for critical issues.",
    ),
    JudgedMessage(
        "j116", "Mon, 26 Feb 2024 14:15:00 +0000",
        "alice@example.com", "office@northgate.example.com",
        "Standing desk order",
        "The standing desk order for the corner office went through; delivery Thursday.",
    ),
    JudgedMessage(
        "j117", "Tue, 27 Feb 2024 10:30:00 +0000",
        "alice@example.com", "filing@alderfinch.example.com",
        "Expense report approval flow",
        "The expense report approval flow now routes over 500.00 to the managing director.",
    ),
    JudgedMessage(
        "j118", "Wed, 28 Feb 2024 15:50:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Report the expense numbers",
        "Please report the expense numbers to me by Thursday, separate from the quarterly pack.",
    ),
    JudgedMessage(
        "j119", "Thu, 29 Feb 2024 09:45:00 +0000",
        "Tax Office <notices@taxoffice.example.org>", "alice@example.com",
        "Quarterly tax filing window",
        "The quarterly tax filing window opens Monday and closes on the 10th.",
    ),
    JudgedMessage(
        "j120", "Fri, 01 Mar 2024 11:05:00 +0000",
        "alice@example.com", "it@northgate.example.com",
        "Shared drive migration",
        "The shared drive migration moves the archive folder first; bookmark your links.",
    ),
    JudgedMessage(
        "j121", "Mon, 04 Mar 2024 13:20:00 +0000",
        "alice@example.com", "it@northgate.example.com",
        "Two-factor authentication rollout",
        "The two-factor authentication rollout starts with the finance group on Wednesday.",
    ),
    JudgedMessage(
        "j122", "Tue, 05 Mar 2024 08:35:00 +0000",
        "Cedar Run Sales <sales@cedarrun.example.com>", "alice@example.com",
        "Purchase order number missing",
        "The portal rejected the invoice because the purchase order number is missing from the header.",
    ),
    JudgedMessage(
        "j123", "Wed, 06 Mar 2024 12:55:00 +0000",
        "alice@example.com", "procurement@northgate.example.com",
        "Number of purchase orders this quarter",
        "Can you pull the number of purchase orders this quarter for the ops review?",
    ),
    JudgedMessage(
        "j124", "Thu, 07 Mar 2024 10:15:00 +0000",
        "alice@example.com", "legal@cedarrun.example.com",
        "Redline the contract today",
        "Please redline the contract today; legal review closes tomorrow noon.",
    ),
    JudgedMessage(
        "j125", "Fri, 08 Mar 2024 09:00:00 +0000",
        "alice@example.com", "management@lakeview.example.com",
        "Final walkthrough",
        "The final walkthrough of the apartment is set for the last day of the lease.",
    ),
]

// MARK: - Category L: Attachment-only text (j126-j140)

let attachmentMessages: [JudgedMessage] = [
    JudgedMessage(
        "j126", "Mon, 11 Mar 2024 09:40:00 +0000",
        "alice@example.com", "procurement@northgate.example.com",
        "Line items for the order",
        "The line items are in the attached sheet; totals match the confirmation.",
        attachments: [JudgedAttachment("line-items.csv", "text/csv",
            "part,description,qty\nFB-114,industrial fan belt,4\nHD-7710,hex bolt kit M8,20\n")]
    ),
    JudgedMessage(
        "j127", "Tue, 12 Mar 2024 10:50:00 +0000",
        "Alumni Office <events@alumni.example.org>", "alice@example.com",
        "Alumni weekend schedule",
        "The alumni weekend schedule is attached as a page for offline reading.",
        attachments: [JudgedAttachment("alumni-schedule.html", "text/html",
            "<h1>Alumni weekend</h1><p>Saturday: campus tour at 10, rowing regatta at 14, dinner at 19.</p>")]
    ),
    JudgedMessage(
        "j128", "Wed, 13 Mar 2024 11:25:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Agenda for Thursday",
        "Agenda attached; add anything under other business by tonight.",
        attachments: [JudgedAttachment("agenda.txt", "text/plain",
            "agenda Thursday: hiring plan, offsite votes, action items for Priya, vendor scorecard\n")]
    ),
    JudgedMessage(
        "j129", "Thu, 14 Mar 2024 13:35:00 +0000",
        "alice@example.com", "filing@alderfinch.example.com",
        "Expense export",
        "The expense export for February is attached.",
        attachments: [JudgedAttachment("expenses-feb.csv", "text/csv",
            "date,vendor,amount,note\n2024-02-07,taxi reimbursement,42.00,warehouse visit\n2024-02-12,café meeting,18.50,review with team\n")]
    ),
    JudgedMessage(
        "j130", "Fri, 15 Mar 2024 08:15:00 +0000",
        "Cedaroft Wares <catalog@cedaroft.example.com>", "alice@example.com",
        "Inventory list February",
        "Inventory list attached; the hardware counts were recounted twice.",
        attachments: [JudgedAttachment("inventory-feb.csv", "text/csv",
            "part,description,on_hand\nHD-7710,hex bolt kit M8,34\nFB-114,industrial fan belt,2\n")]
    ),
    JudgedMessage(
        "j131", "Mon, 18 Mar 2024 10:05:00 +0000",
        "alice@example.com", "people@northgate.example.com",
        "Timesheet reminder",
        "Timesheet CSV attached for the week; note the offsite day counts as working time.",
        attachments: [JudgedAttachment("timesheet-w9.csv", "text/csv",
            "day,hours,project\nMon,8,retail analytics\nTue,6,retail analytics\nWed,4,offsite prep\n")]
    ),
    JudgedMessage(
        "j132", "Tue, 19 Mar 2024 14:55:00 +0000",
        "Office Manager <office@northgate.example.com>", "alice@example.com",
        "Seating chart update",
        "The updated seating chart is attached; the corner office swaps with the analytics pod.",
        attachments: [JudgedAttachment("seating-chart.txt", "text/plain",
            "seating chart v3: corner office = Maya, analytics pod = Priya and team\n")]
    ),
    JudgedMessage(
        "j133", "Wed, 20 Mar 2024 09:30:00 +0000",
        "Cedaroft Wares <catalog@cedaroft.example.com>", "alice@example.com",
        "Vendor catalog spring",
        "The vendor catalog for spring is attached; new part numbers start at HD-7700.",
        attachments: [JudgedAttachment("catalog-spring.csv", "text/csv",
            "part,description,price\nHD-7710,hex bolt kit M8,12.50\nHD-7720,pressure gauge,58.00\n")]
    ),
    JudgedMessage(
        "j134", "Thu, 21 Mar 2024 15:40:00 +0000",
        "Alumni Office <events@alumni.example.org>", "alice@example.com",
        "Reading list",
        "The spring reading list from the book club is attached as a page.",
        attachments: [JudgedAttachment("reading-list.html", "text/html",
            "<h1>Reading list</h1><p>March: the cartographer's daughter. April: salt and stone.</p>")]
    ),
    JudgedMessage(
        "j135", "Fri, 22 Mar 2024 08:25:00 +0000",
        "Studio Manager <manager@studio.example.org>", "alice@example.com",
        "Studio access notes",
        "Access notes attached; the door code changes Friday.",
        attachments: [JudgedAttachment("access-notes.txt", "text/plain",
            "studio access: door code 4-7-2 until Friday, wifi password studio-2024-spring\n")]
    ),
    JudgedMessage(
        "j136", "Mon, 25 Mar 2024 11:45:00 +0000",
        "Alder & Finch <payroll@alderfinch.example.com>", "alice@example.com",
        "Payroll run April",
        "The payroll run for April is attached; check the overtime column before Friday.",
        attachments: [JudgedAttachment("payroll-run-april.csv", "text/csv",
            "employee,base,overtime\nanalyst-1,5200.00,0\nanalyst-2,5200.00,340.00\n")]
    ),
    JudgedMessage(
        "j137", "Tue, 26 Mar 2024 13:55:00 +0000",
        "Cedar Run Billing <billing@cedarrun.example.com>", "alice@example.com",
        "Invoice page for the portal",
        "The invoice page for the portal is attached; the net-30 terms are stated at the bottom.",
        attachments: [JudgedAttachment("invoice-2024-0057.html", "text/html",
            "<h1>Invoice 2024-0057</h1><p>Total 12,400.00, terms net-30, reference PO-8841.</p>")]
    ),
    JudgedMessage(
        "j138", "Wed, 27 Mar 2024 09:20:00 +0000",
        "Northgate Office <office@northgate.example.com>", "alice@example.com",
        "Drill schedule",
        "The drill schedule for the quarter is attached.",
        attachments: [JudgedAttachment("drill-schedule.txt", "text/plain",
            "drill schedule: fire drill March 28 10:00, shelter drill April 11 15:00\n")]
    ),
    JudgedMessage(
        "j139", "Thu, 28 Mar 2024 16:05:00 +0000",
        "Northgate IT <it@northgate.example.com>", "alice@example.com",
        "VPN audit",
        "The VPN audit export is attached; three dormant profiles to revoke.",
        attachments: [JudgedAttachment("vpn-audit.csv", "text/csv",
            "profile,last_used,status\nanalyst-9,2023-11-02,dormant\ncontractor-2,2023-09-14,dormant\n")]
    ),
    JudgedMessage(
        "j140", "Fri, 29 Mar 2024 10:35:00 +0000",
        "Cedar Run Support <support@cedarrun.example.com>", "alice@example.com",
        "Release notes 2.4.1",
        "Release notes for 2.4.1 are attached as a page.",
        attachments: [JudgedAttachment("release-notes.html", "text/html",
            "<h1>Release notes 2.4.1</h1><p>Fixed: seat expansion double-count. Added: renewal discount preview.</p>")]
    ),
]

// MARK: - Category M: Trigram and substring fixtures (j141-j150)

let trigramMessages: [JudgedMessage] = [
    JudgedMessage(
        "j141", "Mon, 01 Apr 2024 09:15:00 +0000",
        "Meridian Bank <accounts@meridian.example.com>", "alice@example.com",
        "Account statement available",
        "Your acct 4417 statement is ready; the interest posting this month is 12.40.",
    ),
    JudgedMessage(
        "j142", "Tue, 02 Apr 2024 10:30:00 +0000",
        "alice@example.com", "filing@alderfinch.example.com",
        "Bank account for the audit",
        "For the audit trail, the bank account ending 4417 is the operating account, not the payroll one.",
    ),
    JudgedMessage(
        "j143", "Wed, 03 Apr 2024 11:45:00 +0000",
        "Warner Supplies <orders@warner.example.com>", "alice@example.com",
        "Warner Supplies quote",
        "Warner Supplies quotes the shelving units at 210 each with delivery in two weeks.",
    ),
    JudgedMessage(
        "j144", "Thu, 04 Apr 2024 14:00:00 +0000",
        "alice@example.com", "orders@warner.example.com",
        "Re: Warner Supplies quote",
        "Accepting the Warner Supplies quote for six units; invoice to the usual address.",
    ),
    JudgedMessage(
        "j145", "Fri, 05 Apr 2024 09:20:00 +0000",
        "Birchline Orders <orders@birchline.example.com>", "alice@example.com",
        "Order BX-2215 update",
        "Order BX-2215 (the replacement belts) cleared customs and ships Monday.",
    ),
    JudgedMessage(
        "j146", "Mon, 08 Apr 2024 10:40:00 +0000",
        "alice@example.com", "procurement@northgate.example.com",
        "Gauge part number check",
        "Confirm the gauge part number before we reorder: the catalog lists HD-7720, the invoice says HD-7721.",
    ),
    JudgedMessage(
        "j147", "Tue, 09 Apr 2024 12:55:00 +0000",
        "Meridian Bank <accounts@meridian.example.com>", "alice@example.com",
        "Card reader for acct 4417",
        "The replacement card reader for acct 4417 ships this week; activation takes a call.",
    ),
    JudgedMessage(
        "j148", "Wed, 10 Apr 2024 08:30:00 +0000",
        "Northgate IT <it@northgate.example.com>", "alice@example.com",
        "Asset tag list",
        "Asset tags for the new laptops start at 4417; the list is in the asset system.",
    ),
    JudgedMessage(
        "j149", "Thu, 11 Apr 2024 15:10:00 +0000",
        "Gardner Mailing <orders@gardner.example.com>", "alice@example.com",
        "Gardner mailing house booking",
        "The Gardner mailing house can take the spring mailing the week of the 22nd.",
    ),
    JudgedMessage(
        "j150", "Fri, 12 Apr 2024 09:55:00 +0000",
        "alice@example.com", "team@northgate.example.com",
        "Kernel version pinned",
        "The kernel version is pinned to 6.6.21 in the staging clusters; production follows next window.",
    ),
]
