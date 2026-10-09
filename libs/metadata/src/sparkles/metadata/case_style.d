/**
The identifier case styles: vocabulary only.

`sparkles.base.text.case_style` converts between them; the `@WireCase`
attribute ($(MREF sparkles,metadata,wire)) names one. Both need the enum, and
`sparkles:base` depends on this package, so the enum lives here.
*/
module sparkles.metadata.case_style;

/// The case styles an identifier can be rejoined into.
enum CaseStyle
{
    original,           /// return the identifier unchanged (no split/rejoin)
    camelCase,          /// `fromXmlToJson` — lowercase first word, title-case the rest
    pascalCase,         /// `FromXmlToJson` — title-case every word
    snakeCase,          /// `from_xml_to_json` — lowercase words joined with `_`
    kebabCase,          /// `from-xml-to-json` — lowercase words joined with `-`
    screamingSnakeCase, /// `FROM_XML_TO_JSON` — uppercase words joined with `_`
}
