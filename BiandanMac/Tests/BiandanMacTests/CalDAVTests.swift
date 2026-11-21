import XCTest
@testable import BiandanMac

final class CalDAVTests: XCTestCase {
    private let base = URL(string: "https://dav.example.com/calendars/alice/")!

    func testServerURLNormalization() {
        XCTAssertEqual(CalDAVClient.serverURL("caldav.feishu.cn")?.absoluteString, "https://caldav.feishu.cn")
        XCTAssertEqual(CalDAVClient.serverURL("  https://caldav.icloud.com/ ")?.absoluteString, "https://caldav.icloud.com/")
        XCTAssertEqual(CalDAVClient.serverURL("caldav://dav.example.com/cal")?.absoluteString, "https://dav.example.com/cal")
        XCTAssertNil(CalDAVClient.serverURL("http://insecure.example.com"))
        XCTAssertNil(CalDAVClient.serverURL("   "))
    }

    func testSameSiteForRedirects() {
        XCTAssertTrue(CalDAVClient.sameSite("caldav.icloud.com", "p01-caldav.icloud.com"))
        XCTAssertTrue(CalDAVClient.sameSite("a.example.com.cn", "b.example.com.cn"))
        XCTAssertFalse(CalDAVClient.sameSite("a.example.com.cn", "b.other.com.cn"))
        XCTAssertFalse(CalDAVClient.sameSite("example.com", "evil.com"))
        XCTAssertFalse(CalDAVClient.sameSite("", ""))
    }

    func testPrincipalAndCalendarHome() throws {
        let principal = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop>
            <d:current-user-principal><d:href>/principals/alice/</d:href></d:current-user-principal>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
            """
        XCTAssertEqual(try CalDAVClient.parsePrincipal(Data(principal.utf8), base: base)?.absoluteString,
                       "https://dav.example.com/principals/alice/")

        let home = """
            <?xml version="1.0"?>
            <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><D:response>
            <D:href>/principals/alice/</D:href><D:propstat><D:prop><C:calendar-home-set>
            <D:href>https://p07-caldav.example.com/123/calendars/</D:href></C:calendar-home-set></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
            """
        XCTAssertEqual(try CalDAVClient.parseCalendarHome(Data(home.utf8), base: base)?.absoluteString,
                       "https://p07-caldav.example.com/123/calendars/")
        XCTAssertThrowsError(try CalDAVClient.parsePrincipal(Data("<html></html>".utf8), base: base))
    }

    func testCalendarListKeepsOnlyEventCalendars() throws {
        let xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">
            <d:response><d:href>/calendars/alice/</d:href><d:propstat><d:prop>
              <d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/calendars/alice/work/</d:href><d:propstat><d:prop>
              <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>工作</d:displayname>
              <c:supported-calendar-component-set><c:comp name="VEVENT"/><c:comp name="VTODO"/></c:supported-calendar-component-set>
              <a:calendar-color>#FF8800FF</a:calendar-color></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/calendars/alice/tasks/</d:href><d:propstat><d:prop>
              <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>提醒事项</d:displayname>
              <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
              </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/calendars/alice/inbox/</d:href><d:propstat><d:prop>
              <d:resourcetype><d:collection/><c:schedule-inbox/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/calendars/alice/home%20cal/</d:href>
              <d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
              <d:propstat><d:prop><a:calendar-color/><d:displayname/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
            </d:response></d:multistatus>
            """
        let calendars = try CalDAVClient.parseCalendars(Data(xml.utf8), base: base)
        XCTAssertEqual(calendars.map(\.name), ["工作", "home cal"])
        XCTAssertEqual(calendars.first?.url.absoluteString, "https://dav.example.com/calendars/alice/work/")
        XCTAssertEqual(calendars.first?.color, "#FF8800FF")
        XCTAssertNil(calendars.last?.color)
    }

    func testCalendarDataAndMissingResources() throws {
        let xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:response><d:href>/cal/a.ics</d:href><d:propstat><d:prop><d:getetag>"1"</d:getetag>
            <c:calendar-data>BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:a
            SUMMARY:评审 &amp; 复盘
            DTSTART:20261201T020000Z
            DTEND:20261201T030000Z
            END:VEVENT
            END:VCALENDAR
            </c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/cal/b.ics</d:href><d:propstat><d:prop><c:calendar-data/></d:prop>
            <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
            <d:response><d:href>/cal/</d:href><d:propstat><d:prop><d:getetag/></d:prop>
            <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            </d:multistatus>
            """
        let parsed = try CalDAVClient.parseCalendarData(Data(xml.utf8), base: base)
        XCTAssertEqual(parsed.texts.count, 1)
        XCTAssertEqual(parsed.missing, ["/cal/b.ics"])
        let today = LocalDate(iso: "2026-11-21")!
        let events = ICSImport.parse(parsed.texts[0], today: today).events
        XCTAssertEqual(events.map(\.title), ["评审 & 复盘"])
    }

    func testSourceNaming() {
        XCTAssertEqual(AppModel.caldavSourceName(account: "飞书", calendar: "我的日历"), "飞书·我的日历")
        XCTAssertEqual(AppModel.caldavSourceName(account: "", calendar: "工作"), "工作")
        XCTAssertEqual(AppModel.caldavSourceName(account: "钉钉", calendar: "钉钉"), "钉钉")
        XCTAssertEqual(AppModel.caldavSourceName(account: " ", calendar: " "), "CalDAV 日历")
    }

    func testSubscriptionURLNormalization() {
        XCTAssertEqual(ICSSubscription.url("webcal://p01.example.com/a.ics")?.absoluteString, "https://p01.example.com/a.ics")
        XCTAssertEqual(ICSSubscription.url("WEBCALS://x.example.com/b?token=1")?.absoluteString, "https://x.example.com/b?token=1")
        XCTAssertEqual(ICSSubscription.url("http://a.example.com/x.ics")?.absoluteString, "https://a.example.com/x.ics")
        XCTAssertEqual(ICSSubscription.url(" calendar.example.com/c.ics ")?.absoluteString, "https://calendar.example.com/c.ics")
        XCTAssertNil(ICSSubscription.url("ftp://x.example.com/a.ics"))
        XCTAssertNil(ICSSubscription.url("  "))
    }

    func testImportIntervalTitles() {
        XCTAssertEqual(AppModel.importSyncChoices.map(AppModel.importIntervalTitle),
                       ["5 分钟", "15 分钟", "30 分钟", "1 小时", "3 小时", "仅手动"])
        XCTAssertTrue(AppModel.importSyncChoices.contains(AppModel.defaultImportSyncMinutes))
    }
}
