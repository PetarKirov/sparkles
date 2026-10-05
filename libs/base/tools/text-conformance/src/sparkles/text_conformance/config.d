/** All conformance layers use the checked-in generated manifest identity.
 * Changing a compiler cannot select another Unicode property release.
 */
module sparkles.text_conformance.config;

import sparkles.base.text.unicode_tables : unicodeVersion, unicodeManifestIdentity;

enum size_t layerCount = 17;

struct Config
{
    bool[layerCount] layers = true;
    /// Root containing the manifest's ucd/, emoji/ and license artifacts.
    string ucdDir;
    bool noNetwork;
    /// The exact manifest used to generate the implementation under test.
    string manifestPath = "libs/base/tools/unicode/manifest.json";
    enum versionIdentity = unicodeVersion;
    enum manifestIdentity = unicodeManifestIdentity;
    bool requireKitty;
    string allowlistPath;
    bool updateAllowlist;
}
