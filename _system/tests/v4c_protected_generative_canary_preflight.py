#!/usr/bin/env python3
import argparse, hashlib, json, math, os, tempfile, urllib.request
from pathlib import Path

from PIL import Image


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def write_json(path, obj):
    Path(path).write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def download(url, path):
    req = urllib.request.Request(url, headers={'User-Agent': 'TinySnow/1.0'})
    with urllib.request.urlopen(req, timeout=45) as r, open(path, 'wb') as f:
        f.write(r.read())


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def median(values):
    s = sorted(values)
    n = len(s)
    if not n:
        return 255
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) // 2


def estimate_background(im):
    im = im.convert('RGB')
    w, h = im.size
    sample = max(2, min(w, h) // 80)
    pts = []
    for x0, y0 in ((0, 0), (max(0, w - sample), 0), (0, max(0, h - sample)), (max(0, w - sample), max(0, h - sample))):
        for y in range(y0, min(h, y0 + sample)):
            for x in range(x0, min(w, x0 + sample)):
                pts.append(im.getpixel((x, y)))
    return tuple(median([p[i] for p in pts]) for i in range(3))


def foreground_tiles(im, bg, threshold=26.0):
    im = im.convert('RGB')
    w, h = im.size
    tile = max(12, min(w, h) // 28)
    cols = math.ceil(w / tile)
    rows = math.ceil(h / tile)
    marked = [[False] * cols for _ in range(rows)]
    for ty in range(rows):
        y0, y1 = ty * tile, min(h, (ty + 1) * tile)
        for tx in range(cols):
            x0, x1 = tx * tile, min(w, (tx + 1) * tile)
            total = 0
            fg = 0
            # stride keeps this deterministic and cheap without OCR.
            stride = max(1, tile // 8)
            for y in range(y0, y1, stride):
                for x in range(x0, x1, stride):
                    r, g, b = im.getpixel((x, y))
                    d = math.sqrt((r-bg[0])**2 + (g-bg[1])**2 + (b-bg[2])**2)
                    total += 1
                    if d > threshold:
                        fg += 1
            if total and fg / total >= 0.06:
                marked[ty][tx] = True
    # one-tile safety dilation around foreground/text/badges
    dilated = [[False] * cols for _ in range(rows)]
    for ty in range(rows):
        for tx in range(cols):
            if not marked[ty][tx]:
                continue
            for yy in range(max(0, ty-1), min(rows, ty+2)):
                for xx in range(max(0, tx-1), min(cols, tx+2)):
                    dilated[yy][xx] = True
    return dilated, tile


def components(mask):
    rows = len(mask); cols = len(mask[0]) if rows else 0
    seen = set(); comps = []
    for y in range(rows):
        for x in range(cols):
            if not mask[y][x] or (x,y) in seen:
                continue
            stack=[(x,y)]; seen.add((x,y)); pts=[]
            while stack:
                cx,cy=stack.pop(); pts.append((cx,cy))
                for nx,ny in ((cx-1,cy),(cx+1,cy),(cx,cy-1),(cx,cy+1)):
                    if 0 <= nx < cols and 0 <= ny < rows and mask[ny][nx] and (nx,ny) not in seen:
                        seen.add((nx,ny)); stack.append((nx,ny))
            comps.append(pts)
    return comps


def regions_from_mask(mask, tile, width, height):
    regs=[]
    for i, pts in enumerate(components(mask), 1):
        minx=min(x for x,_ in pts); maxx=max(x for x,_ in pts)
        miny=min(y for _,y in pts); maxy=max(y for _,y in pts)
        x0=minx*tile; y0=miny*tile
        x1=min(width,(maxx+1)*tile); y1=min(height,(maxy+1)*tile)
        regs.append({
            'name': f'foreground_component_{i}',
            'x': round(x0/width, 6),
            'y': round(y0/height, 6),
            'width': round((x1-x0)/width, 6),
            'height': round((y1-y0)/height, 6),
            'source': 'DETERMINISTIC_BACKGROUND_CONTRAST_TILE_MASK'
        })
    regs.sort(key=lambda r: r['width']*r['height'], reverse=True)
    return regs


def union_tile_ratio(mask):
    if not mask or not mask[0]: return 1.0
    total=len(mask)*len(mask[0])
    marked=sum(1 for row in mask for v in row if v)
    return marked/total


def evaluate_candidate(cand, workdir):
    variants=cand.get('variant_options') or []
    if len(variants) != 1:
        return {'eligible': False, 'reason': 'REQUIRE_EXACTLY_ONE_VARIANT'}
    v=variants[0]
    url=v.get('option_image_url')
    if not url:
        return {'eligible': False, 'reason': 'MISSING_SOURCE_URL'}
    p=Path(workdir)/f"{cand['product_id']}.img"
    try:
        download(url,p)
        with Image.open(p) as im:
            im.load()
            w,h=im.size
            bg=estimate_background(im)
            mask,tile=foreground_tiles(im,bg)
            protected=regions_from_mask(mask,tile,w,h)
            protected_ratio=union_tile_ratio(mask)
            editable_ratio=max(0.0,1.0-protected_ratio)
        if not protected:
            return {'eligible': False, 'reason':'NO_PROTECTED_FOREGROUND_DETECTED'}
        if len(protected) > 20:
            return {'eligible': False, 'reason':'TOO_MANY_PROTECTED_COMPONENTS','protected_region_count':len(protected)}
        if editable_ratio < 0.12:
            return {'eligible': False, 'reason':'INSUFFICIENT_SAFE_EDITABLE_BACKGROUND','editable_area_ratio':round(editable_ratio,6)}
        return {
            'eligible': True,
            'product_id': str(cand['product_id']),
            'variant_identity_key': v['variant_identity_key'],
            'variation_name': v.get('variation_name'),
            'option_name': v.get('option_name'),
            'source_url': url,
            'source_sha256': sha256(p),
            'image_width': w,
            'image_height': h,
            'estimated_background_rgb': list(bg),
            'protected_regions': protected,
            'protected_area_ratio': round(protected_ratio,6),
            'editable_area_ratio': round(editable_ratio,6),
            'edit_contract': 'BACKGROUND_ONLY_GENERATIVE_CLEANUP_WITH_POST_GENERATION_PROTECTED_REGION_RESTORE',
            'region_detection': 'DETERMINISTIC_NON_OCR_BACKGROUND_CONTRAST_TILE_MASK'
        }
    except Exception as e:
        return {'eligible': False, 'reason':'SOURCE_PREFLIGHT_ERROR', 'error': str(e)[:300]}


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--source-preflight', required=True)
    ap.add_argument('--guard-validation', required=True)
    ap.add_argument('--out', required=True)
    args=ap.parse_args()
    src=read_json(args.source_preflight)
    guard=read_json(args.guard_validation)
    assert src.get('status')=='PASS', 'SOURCE_TRUTH_CANARY_PREFLIGHT_NOT_PASS'
    assert guard.get('status')=='PASS' and guard.get('zero_paid') is True, 'SOURCE_PRESERVATION_GUARD_NOT_PASS'
    assert guard['routing']['protected_generative']=='GENERATIVE_WITH_PROTECTED_REGION_RESTORE'
    candidates=src.get('preferred_minimal_candidate_products') or src.get('first_20_candidate_products') or []
    attempts=[]; selected=None
    with tempfile.TemporaryDirectory(prefix='tinysnow-protected-canary-') as td:
        for cand in candidates[:20]:
            r=evaluate_candidate(cand,td)
            attempts.append({'product_id':str(cand.get('product_id')),'result':r})
            if r.get('eligible'):
                selected=r; break
    out={
        'schema_version':'tinysnow.protected-generative-canary-preflight.1',
        'status':'PASS' if selected else 'HOLD_NO_SAFE_GENERATIVE_CANDIDATE',
        'zero_paid':True,
        'image_generation_called':False,
        'stable_mutation':False,
        'c5_3_rerun':False,
        'selection_rule':'Source Truth exact variant + deterministic non-OCR foreground protection + >=12% editable background; no full-frame generative edit.',
        'selected':selected,
        'attempts':attempts,
        'next_action':'OWNER_GATE_FOR_SECOND_MINIMAL_PROTECTED_CANARY' if selected else 'IMPROVE_ZERO_PAID_REGION_DISCOVERY',
        'second_paid_request_authorized':False,
        'bulk_generation_authorized':False
    }
    write_json(args.out,out)
    print(json.dumps(out,ensure_ascii=False,indent=2))
    if not selected:
        raise SystemExit(3)

if __name__=='__main__':
    main()
