"""테스트용 문서를 만든다.

- 평범한 문서는 **도구 자신의 `create` 액션**으로 만든다(그쪽도 같이 검증된다).
- 셰이프 종류·자리표시자 상속을 보려면 그런 구조가 실제로 든 덱이 필요한데,
  `create` 가 만드는 덱은 비어 있으므로 여기서 **최소 pptx 를 직접 조립**한다.
  PowerPoint 로 열리는 것이 목적이 아니라 **읽기 경로를 태우는 것**이 목적이다.
"""
import os
import zipfile

from harness import call

P = "http://schemas.openxmlformats.org/presentationml/2006/main"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG = "http://schemas.openxmlformats.org/package/2006/relationships"
NS = 'xmlns:p="%s" xmlns:a="%s" xmlns:r="%s"' % (P, A, R)
DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'

# 1cm = 360000 EMU
CM = 360000


def _xfrm(x_cm, y_cm, w_cm, h_cm):
    return ('<a:xfrm><a:off x="%d" y="%d"/><a:ext cx="%d" cy="%d"/></a:xfrm>'
            % (x_cm * CM, y_cm * CM, w_cm * CM, h_cm * CM))


def _sp(sid, name, body_pr, sp_pr, text=""):
    txt = ('<p:txBody><a:bodyPr/><a:p><a:r><a:t>%s</a:t></a:r></a:p></p:txBody>'
           % text) if text else '<p:txBody><a:bodyPr/><a:p/></p:txBody>'
    return ('<p:sp><p:nvSpPr><p:cNvPr id="%d" name="%s"/>%s</p:nvSpPr>'
            '<p:spPr>%s</p:spPr>%s</p:sp>' % (sid, name, body_pr, sp_pr, txt))


def _tree(shapes):
    return ('<p:cSld><p:spTree>'
            '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
            '<p:grpSpPr/>%s</p:spTree></p:cSld>' % "".join(shapes))


def _rels(items):
    body = "".join(
        '<Relationship Id="rId%d" Type="%s" Target="%s"/>' % (i + 1, t, tgt)
        for i, (t, tgt) in enumerate(items)
    )
    return DECL + '<Relationships xmlns="%s">%s</Relationships>' % (PKG, body)


def deck_with_shapes(path):
    """셰이프 종류가 골고루 든 덱을 만든다.

    슬라이드 1의 셰이프 순서(= list_shapes 의 index):
      0 제목 자리표시자 — **슬라이드에 위치가 없다**(레이아웃에서 상속)
      1 텍스트박스      — 위치 있음
      2 타원(도형)      — 위치 있음, prstGeom=ellipse
      3 그림(picture)   — text 속성이 없어 python-pptx 스크립트가 죽던 자리
      4 표(graphicFrame)
      5 그룹(grpSp)
      6 연결선(cxnSp)
    """
    slide_shapes = [
        # 0: 자리표시자. spPr 이 비어 있다 = 위치를 레이아웃에서 물려받는다.
        _sp(2, "Title 1",
            '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
            '<p:nvPr><p:ph type="ctrTitle"/></p:nvPr>',
            "", "제목입니다"),
        # 1: 텍스트박스(txBox="1")
        _sp(3, "TextBox 2",
            '<p:cNvSpPr txBox="1"/><p:nvPr/>',
            _xfrm(1, 2, 6, 1), "본문 텍스트"),
        # 2: 도형(타원)
        _sp(4, "Oval 5",
            '<p:cNvSpPr/><p:nvPr/>',
            _xfrm(3, 4, 2, 2) + '<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>'),
        # 3: 그림
        '<p:pic><p:nvPicPr><p:cNvPr id="5" name="Picture 6"/><p:cNvPicPr/>'
        '<p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId9"/></p:blipFill>'
        '<p:spPr>%s</p:spPr></p:pic>' % _xfrm(5, 6, 4, 3),
        # 4: 표
        '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="6" name="Table 7"/>'
        '<p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>'
        '<p:xfrm><a:off x="%d" y="%d"/><a:ext cx="%d" cy="%d"/></p:xfrm>'
        '<a:graphic><a:graphicData uri="%s/table"/></a:graphic></p:graphicFrame>'
        % (1 * CM, 8 * CM, 5 * CM, 2 * CM, "http://schemas.openxmlformats.org/drawingml/2006"),
        # 5: 그룹
        '<p:grpSp><p:nvGrpSpPr><p:cNvPr id="7" name="Group 8"/><p:cNvGrpSpPr/>'
        '<p:nvPr/></p:nvGrpSpPr><p:grpSpPr>%s</p:grpSpPr></p:grpSp>' % _xfrm(7, 8, 3, 3),
        # 6: 연결선
        '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="8" name="Connector 9"/><p:cNvCxnSpPr/>'
        '<p:nvPr/></p:nvCxnSpPr><p:spPr>%s</p:spPr></p:cxnSp>' % _xfrm(2, 9, 4, 0),
    ]

    # 레이아웃: 제목 자리표시자에 **실제 위치**를 준다(슬라이드가 이걸 물려받는다).
    layout_shapes = [
        _sp(2, "Title Placeholder 1",
            '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
            '<p:nvPr><p:ph type="title"/></p:nvPr>',
            _xfrm(2, 1, 20, 3)),
        _sp(3, "Subtitle Placeholder 2",
            '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
            '<p:nvPr><p:ph type="subTitle" idx="1"/></p:nvPr>',
            _xfrm(2, 5, 20, 8)),
    ]
    # 마스터: 레이아웃에 없는 종류(ftr)만 여기서 찾도록 둔다.
    master_shapes = [
        _sp(2, "Footer Placeholder 1",
            '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
            '<p:nvPr><p:ph type="ftr" idx="9"/></p:nvPr>',
            _xfrm(1, 17, 6, 1)),
    ]

    parts = {
        "[Content_Types].xml": DECL + (
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package'
            '.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
            '</Types>'),
        "_rels/.rels": _rels([("%s/officeDocument" % R, "ppt/presentation.xml")]),
        "ppt/presentation.xml": DECL + '<p:presentation %s/>' % NS,
        "ppt/slides/slide1.xml": DECL + '<p:sld %s>%s</p:sld>' % (NS, _tree(slide_shapes)),
        "ppt/slides/_rels/slide1.xml.rels": _rels([
            ("%s/slideLayout" % R, "../slideLayouts/slideLayout1.xml")]),
        "ppt/slideLayouts/slideLayout1.xml":
            DECL + '<p:sldLayout %s>%s</p:sldLayout>' % (NS, _tree(layout_shapes)),
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels": _rels([
            ("%s/slideMaster" % R, "../slideMasters/slideMaster1.xml")]),
        "ppt/slideMasters/slideMaster1.xml":
            DECL + '<p:sldMaster %s>%s</p:sldMaster>' % (NS, _tree(master_shapes)),
    }
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, text in parts.items():
            zf.writestr(name, text)
    return path


def make(suite, name, title="test"):
    """도구의 `create` 액션으로 빈 문서를 만든다(워크스페이스 기준 상대 경로)."""
    out = call("document_advanced",
               {"path": name, "action": "create", "args": {"title": title}},
               suite.ws)
    if not out.get("ok"):
        raise AssertionError("fixture 생성 실패(%s): %s" % (name, out.get("error")))
    return name
