import Foundation

/// Fictional mail stored only on this Mac. Dates are anchored to first launch.
public enum DemoFixtures {
    public static func makeSnapshot(now: Date = Date()) -> AppSnapshot {
        let personalAddress = MailAddress(name: "Alex Morgan", email: "alex.morgan@example.test")
        let schoolAddress = MailAddress(name: "Alex Morgan", email: "alex.morgan@university.example.test")
        let personal = MailAccount(name: "Personal (Demo)", address: personalAddress)
        let university = MailAccount(name: "University (Demo)", address: schoolAddress)
        let school = MailCategory(name: "School", color: "blue")
        let work = MailCategory(name: "Work", color: "indigo")
        let finance = MailCategory(name: "Finance", color: "green")
        let shopping = MailCategory(name: "Shopping", color: "orange")
        let travel = MailCategory(name: "Travel", color: "teal")
        let research = MailCategory(name: "Research", color: "purple")
        let other = MailCategory(name: "Other", color: "sage")
        let categories = [school, work, finance, shopping, travel, research, other]

        let professor = MailAddress(name: "Professor Elaine Lin", email: "e.lin@university.example.test")
        let maya = MailAddress(name: "Maya Chen", email: "maya@studio.example.test")
        let john = MailAddress(name: "John Smith", email: "john@studio.example.test")
        let linThread = UUID()
        let mayaThread = UUID()
        let johnThread = UUID()
        let calendar = Calendar.current
        let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let nextFriday = calendar.nextDate(after: now, matching: DateComponents(hour: 17, weekday: 6), matchingPolicy: .nextTime) ?? now.addingTimeInterval(5 * 86_400)
        let thursdayDate = calendar.date(byAdding: .day, value: -1, to: nextFriday) ?? nextFriday.addingTimeInterval(-86_400)
        let tripDate = calendar.date(byAdding: .day, value: 9, to: now) ?? now.addingTimeInterval(9 * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d"
        let tomorrow = formatter.string(from: tomorrowDate)
        let friday = formatter.string(from: nextFriday)
        let thursday = formatter.string(from: thursdayDate)
        let trip = formatter.string(from: tripDate)
        func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func sender(_ name: String, _ email: String) -> MailAddress { MailAddress(name: name, email: email) }

        let assignment = MailMessage(
            accountID: university.id, threadID: linThread, from: professor, to: [schoolAddress],
            subject: "PHYS 204 · Assignment deadline extended",
            body: """
            Hi Alex,

            The PHYS 204 assignment deadline has changed from \(thursday) at 5:00 PM to \(friday) at 5:00 PM.
            Please submit your problem set through the course portal by the new deadline.
            The additional day should give everyone time to incorporate our discussion of electromagnetic induction in this morning’s lecture.

            Office hours will remain in Room 214 from 2:00 to 3:00 PM tomorrow.
            If you have already submitted your assignment, you can replace it in the portal until the new deadline.

            Best,
            Elaine Lin
            Department of Physics

            --- Previous message ---
            The original assignment deadline was Thursday at 5:00 PM.
            """,
            date: minutesAgo(12), isFlagged: true
        )
        let assignmentOriginal = MailMessage(
            accountID: university.id, threadID: linThread, from: professor, to: [schoolAddress],
            subject: "PHYS 204 · Assignment 3 and office hours",
            body: """
            Hello everyone,

            Assignment 3 covers electromagnetic induction and the applications from this week’s lecture.
            The assignment is due \(thursday) at 5:00 PM.
            Please show your working for each problem and submit one PDF through the course portal.

            Best,
            Elaine Lin
            """,
            date: minutesAgo(2_880), folder: .archive, isRead: true, categoryID: school.id,
            attachments: [MailAttachment(name: "PHYS204-Assignment-3.pdf", size: 248_000)]
        )
        let projectReview = MailMessage(
            accountID: personal.id, threadID: mayaThread, from: maya, to: [personalAddress],
            subject: "Flora project · Design review ready for feedback",
            body: """
            Hi Alex,

            The updated Flora project design review is ready, including the revised inbox and message reader flows.
            Please send feedback on the category confirmation flow by tomorrow, \(tomorrow), at 12:00 PM.
            We need to agree on the empty states before the team review at 4:00 PM.

            I incorporated your note about keeping the original email one click away and made the Undo action visible after archiving.
            The attached review notes explain the three remaining decisions: summary placement, the category suggestion label, and keyboard focus after an action.

            Thanks,
            Maya
            Product Designer · Cedar Studio
            """,
            date: minutesAgo(38), isFlagged: true,
            attachments: [MailAttachment(name: "Flora-Design-Review.pdf", size: 1_340_000)]
        )
        let projectPrevious = MailMessage(
            accountID: personal.id, threadID: mayaThread, from: maya, to: [personalAddress],
            subject: "Flora project · First design review",
            body: """
            Hi Alex,

            Here is the first design review for the Flora project.
            Could you review how the summary, original message, and category controls fit together in the reader?
            The team is trying to reduce the number of steps without hiding the underlying email.

            Thanks,
            Maya
            """,
            date: minutesAgo(2_600), folder: .archive, isRead: true, categoryID: work.id
        )
        let projectReply = MailMessage(
            accountID: personal.id, threadID: mayaThread, from: personalAddress, to: [maya],
            subject: "Re: Flora project · First design review",
            body: """
            Hi Maya,

            I reviewed the reader flow. Please keep the original email one click away and make Undo visible after archiving.
            The category suggestion should also explain that accepting it changes only the local category.

            Thanks,
            Alex
            """,
            date: minutesAgo(2_450), folder: .sent, isRead: true, categoryID: work.id
        )
        let meeting = MailMessage(
            accountID: personal.id, threadID: johnThread, from: john, to: [personalAddress],
            subject: "Project sync moved to tomorrow at 3 PM",
            body: """
            Hi Alex,

            Our project meeting has moved from 2:00 PM to 3:00 PM tomorrow, \(tomorrow).
            Please confirm whether the new time works for you.
            We will meet in the same place, Cedar Studio’s second-floor meeting room, for 30 minutes.

            I would like to cover the prototype walkthrough and agree on the next two priorities.
            There is no preparation needed beyond bringing the latest build.

            Best,
            John
            """,
            date: minutesAgo(65), isFlagged: true
        )
        let meetingPrevious = MailMessage(
            accountID: personal.id, threadID: johnThread, from: john, to: [personalAddress],
            subject: "Project sync · Tomorrow at 2 PM",
            body: """
            Hi Alex,

            Let’s meet tomorrow at 2:00 PM in the second-floor meeting room to walk through the prototype.
            I have reserved 30 minutes for the project sync.

            Best,
            John
            """,
            date: minutesAgo(1_400), folder: .archive, isRead: true, categoryID: work.id
        )
        let messages = [
            assignment, projectReview, meeting,
            MailMessage(
                accountID: personal.id, from: sender("Northstar Bank", "statements@northstar.example.test"), to: [personalAddress],
                subject: "Your monthly account statement is ready",
                body: """
                Hello Alex,

                Your monthly statement is available in your Northstar online account.
                The statement period ended yesterday with a closing balance of $2,418.50.
                Your automatic payment of $86.20 is scheduled for \(friday).
                No action is required if your payment details are up to date.

                For your security, this email does not contain account numbers or a sign-in link.
                This is a fictional demo statement, and no money will move.
                """,
                date: minutesAgo(110), categoryID: finance.id,
                attachments: [MailAttachment(name: "Monthly-Statement.pdf", size: 186_000)]
            ),
            MailMessage(
                accountID: personal.id, from: sender("Field Notes Supply", "orders@fieldnotes.example.test"), to: [personalAddress],
                subject: "Your notebook order is on its way",
                body: """
                Hi Alex,

                Your order FN-10482 has shipped: two dotted notebooks and one pen refill.
                The package arrives tomorrow, \(tomorrow), before 8:00 PM.
                Delivery is scheduled for the reception desk at your selected address.
                No signature is required.

                Thanks,
                Field Notes Supply
                """,
                date: minutesAgo(150), categoryID: shopping.id
            ),
            MailMessage(
                accountID: personal.id, from: sender("Harbor Hotel", "reservations@harbor.example.test"), to: [personalAddress],
                subject: "Your upcoming stay · Reservation HH-3072",
                body: """
                Hello Alex,

                Your two-night hotel reservation begins \(trip).
                Check-in is available from 3:00 PM and check-out is at 11:00 AM.
                Breakfast and Wi-Fi are included in your booking.
                If you expect to arrive after 10:00 PM, please let the front desk know in advance.

                Best regards,
                Harbor Hotel Reservations
                """,
                date: minutesAgo(210), isRead: true, categoryID: travel.id
            ),
            MailMessage(
                accountID: university.id, from: sender("Dr. Nora Patel", "n.patel@university.example.test"), to: [schoolAddress],
                subject: "Research proposal · Participant study feedback",
                body: """
                Hi Alex,

                I have added comments to your research proposal for the human-guided AI study.
                Please revise the participant consent section and explain which interaction metrics the prototype records.
                The paper should distinguish user-confirmed changes from classification predictions.

                For the pilot experiment, six participants will be enough to test whether the tasks and instructions are understandable.
                We can discuss the manuscript in our next supervision session.

                Best,
                Nora
                """,
                date: minutesAgo(260), attachments: [MailAttachment(name: "Research-Proposal-Comments.pdf", size: 620_000)]
            ),
            MailMessage(
                accountID: personal.id, from: sender("Design Dispatch", "newsletter@design.example.test"), to: [personalAddress],
                subject: "Design Dispatch · Interfaces that explain themselves",
                body: """
                This week’s Design Dispatch explores clear labels, useful empty states, and reversible actions.
                Our reading list includes three essays on building calm productivity tools.
                The newsletter also includes an interview about the role of keyboard navigation in desktop applications.
                No action is required; save this for your next reading break.

                --- Newsletter footer ---
                You subscribed to this fictional demo newsletter.
                """,
                date: minutesAgo(310), isRead: true, categoryID: other.id
            ),
            MailMessage(
                accountID: personal.id, from: sender("Cedar Studio Updates", "updates@studio.example.test"), to: [personalAddress],
                subject: "Team update · Next week’s studio hours",
                body: """
                The studio will be open from 9:00 AM to 6:00 PM next week.
                The ground-floor entrance will be closed for maintenance on Monday; use the side entrance instead.
                The project rooms on the second floor will remain open as usual.
                No reply is needed.
                """,
                date: minutesAgo(390), isRead: true, categoryID: work.id
            ),
            MailMessage(
                accountID: university.id, from: sender("University Library", "library@university.example.test"), to: [schoolAddress],
                subject: "Library renewal confirmed",
                body: """
                Your loan of Designing Interactive Systems has been renewed.
                The new return date is \(trip).
                You can view current loans in your library account.
                No action is required.
                """,
                date: minutesAgo(510), isRead: true, categoryID: school.id
            ),
            assignmentOriginal, projectPrevious, projectReply, meetingPrevious,
            MailMessage(
                accountID: personal.id, from: sender("Everyday Store", "offers@everyday.example.test"), to: [personalAddress],
                subject: "Weekend stationery sale",
                body: "A fictional weekend offer: 15% off selected stationery. This promotion has expired. No action is required.",
                date: minutesAgo(4_320), folder: .trash, isRead: true, categoryID: shopping.id
            ),
            MailMessage(
                accountID: university.id, from: schoolAddress, to: [professor],
                subject: "Thank you for today’s office hours",
                body: """
                Hi Professor Lin,

                Thank you for walking through the induction problem during office hours.
                The diagram helped me understand the direction of the induced current.

                Best,
                Alex
                """,
                date: minutesAgo(1_600), folder: .sent, isRead: true, categoryID: school.id
            )
        ]
        let draft = Draft(
            to: john.email, subject: "Re: Project sync moved to tomorrow at 3 PM",
            body: "Hi John,\n\nYes I can meeting tomorrow. Thanks for the update.",
            replyToMessageID: meeting.id, updatedAt: minutesAgo(5)
        )
        return AppSnapshot(accounts: [personal, university], messages: messages, categories: categories, drafts: [draft])
    }
}
