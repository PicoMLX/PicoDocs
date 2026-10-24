//
//  PPTXTemplates.swift
//  PicoDocs
//
//  Fixed PresentationML parts that every PPTX needs but that don't vary with
//  content: the slide master, a blank slide layout, a minimal Office theme, and
//  their relationship files. Kept out of `PPTXExporter` to keep that file focused
//  on slide generation.
//

import Foundation

enum PPTXTemplates {

    static let slideMaster = OOXMLPackageWriter.xmlDeclaration + """
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
    <p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\
    <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
    <p:grpSpPr/></p:spTree></p:cSld>\
    <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
    accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
    <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
    <p:txStyles>\
    <p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle>\
    <p:bodyStyle><a:lvl1pPr><a:defRPr sz="2400"/></a:lvl1pPr></p:bodyStyle>\
    <p:otherStyle/></p:txStyles></p:sldMaster>
    """

    static let slideMasterRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>\
    </Relationships>
    """

    static let slideLayout = OOXMLPackageWriter.xmlDeclaration + """
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="obj" preserve="1">\
    <p:cSld name="Title and Content"><p:spTree>\
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
    <p:grpSpPr/></p:spTree></p:cSld>\
    <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
    """

    static let slideLayoutRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>\
    </Relationships>
    """

    /// Written only when a deck has speaker notes. The slide-image and body
    /// placeholders give PowerPoint's Notes Page its 4:3 layout; neither carries
    /// text or list styles, so imported notes keep their explicit formatting.
    static let notesMaster = OOXMLPackageWriter.xmlDeclaration + """
    <p:notesMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
    <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\
    <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/>\
    <p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr>\
    <p:spPr><a:xfrm><a:off x="1143000" y="685800"/><a:ext cx="4572000" cy="3429000"/></a:xfrm>\
    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr></p:sp>\
    <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/>\
    <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" sz="quarter" idx="3"/></p:nvPr></p:nvSpPr>\
    <p:spPr><a:xfrm><a:off x="685800" y="4343400"/><a:ext cx="5486400" cy="4114800"/></a:xfrm>\
    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
    <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp></p:spTree></p:cSld>\
    <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
    accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
    </p:notesMaster>
    """

    /// Each master owns a theme, so the notes master gets its own copy.
    static let notesMasterRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme2.xml"/>\
    </Relationships>
    """

    static let slideRels = OOXMLPackageWriter.xmlDeclaration + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
    </Relationships>
    """

    /// A minimal but complete Office theme (clrScheme + fontScheme + fmtScheme),
    /// which PowerPoint requires even for plain slides.
    static let theme = OOXMLPackageWriter.xmlDeclaration + """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">\
    <a:themeElements>\
    <a:clrScheme name="Office">\
    <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
    <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="44546A"/></a:dk2>\
    <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>\
    <a:accent1><a:srgbClr val="4472C4"/></a:accent1>\
    <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>\
    <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>\
    <a:accent4><a:srgbClr val="FFC000"/></a:accent4>\
    <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>\
    <a:accent6><a:srgbClr val="70AD47"/></a:accent6>\
    <a:hlink><a:srgbClr val="0563C1"/></a:hlink>\
    <a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="Office">\
    <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="Office">\
    <a:fillStyleLst>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
    <a:lnStyleLst>\
    <a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>\
    <a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>\
    <a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst>\
    <a:effectStyleLst>\
    <a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>\
    </a:themeElements></a:theme>
    """
}
