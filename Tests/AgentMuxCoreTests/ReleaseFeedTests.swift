import Foundation
import Testing
@testable import AgentMuxCore

@Suite struct ReleaseFeedTests {
    @Test func comparesVersions() throws {
        let v = { (s: String) in try #require(ReleaseVersion(s)) }
        #expect(try v("v0.3.0") == v("0.3"))
        #expect(try v("0.3.0") < v("0.3.1"))
        #expect(try v("0.9.9") < v("0.10.0"))
        #expect(try v("1.0") > v("0.99.99"))
        #expect(try v("v1.2.3").description == "1.2.3")
        #expect(ReleaseVersion("0.4.0-beta.1") == nil)
        #expect(ReleaseVersion("latest") == nil)
        #expect(ReleaseVersion("") == nil)
    }

    /// The shape of github.com's releases.atom: newest first, the notes as
    /// escaped HTML, which begin with the install steps.
    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
      <title>Release notes from agentmux</title>
      <link type="text/html" rel="alternate" href="https://github.com/superpung/agentmux/releases"/>
      <entry>
        <id>tag:github.com,2008:Repository/1/v0.2.3</id>
        <link rel="alternate" type="text/html" href="https://github.com/superpung/agentmux/releases/tag/v0.2.3"/>
        <title>v0.2.3</title>
        <content type="html">&lt;h3&gt;Fixed&lt;/h3&gt;
    &lt;ul&gt;
    &lt;li&gt;&lt;strong&gt;Old fix.&lt;/strong&gt; Something.&lt;/li&gt;
    &lt;/ul&gt;</content>
      </entry>
      <entry>
        <id>tag:github.com,2008:Repository/1/v0.3.0</id>
        <link rel="alternate" type="text/html" href="https://github.com/superpung/agentmux/releases/tag/v0.3.0"/>
        <title>v0.3.0</title>
        <content type="html">&lt;h2&gt;Install&lt;/h2&gt;
    &lt;ol&gt;
    &lt;li&gt;
    &lt;p&gt;Download &lt;code&gt;AgentMux-0.3.0-macos-arm64.zip&lt;/code&gt; below, and move &lt;strong&gt;AgentMux.app&lt;/strong&gt; to &lt;code&gt;/Applications&lt;/code&gt;.&lt;/p&gt;
    &lt;/li&gt;
    &lt;/ol&gt;
    &lt;h2&gt;[0.3.0] - 2026-10-30&lt;/h2&gt;
    &lt;h3&gt;Added&lt;/h3&gt;
    &lt;ul&gt;
    &lt;li&gt;&lt;strong&gt;Several agents side by side.&lt;/strong&gt; ⌘-click up to four.&lt;/li&gt;
    &lt;li&gt;&lt;strong&gt;Launch page.&lt;/strong&gt; Every past conversation.&lt;/li&gt;
    &lt;li&gt;&lt;strong&gt;Codex&amp;#39;s account switching&lt;/strong&gt; in place.&lt;/li&gt;
    &lt;li&gt;&lt;strong&gt;Files:&lt;/strong&gt;&lt;/li&gt;
    &lt;/ul&gt;</content>
      </entry>
    </feed>
    """

    @Test func findsTheHighestReleaseAndItsHighlights() throws {
        let latest = try #require(ReleaseFeed.latest(in: Data(Self.feed.utf8)))
        #expect(latest.version.description == "0.3.0")
        #expect(latest.url.absoluteString == "https://github.com/superpung/agentmux/releases/tag/v0.3.0")
        // The install step's bold app name is in a paragraph, not an item's lead.
        #expect(latest.highlights == ["Several agents side by side", "Launch page", "Codex's account switching"])
        #expect(ReleaseFeed.entries(in: Data(Self.feed.utf8)).count == 2)
    }

    @Test func toleratesJunk() {
        #expect(ReleaseFeed.latest(in: Data("not xml".utf8)) == nil)
        #expect(ReleaseFeed.latest(in: Data("<feed></feed>".utf8)) == nil)
    }
}
