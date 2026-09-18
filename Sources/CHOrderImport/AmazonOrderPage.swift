import Foundation

/// JavaScript that reads Amazon.com order pages inside a signed-in `WKWebView`.
///
/// The scripts read only order containers. Recommendations, order totals, and
/// unrelated page links are never treated as purchase rows. They target the
/// desktop layouts observed on the English and Spanish amazon.com storefronts;
/// other marketplaces are not verified.
public enum AmazonOrderPage {
    private static let helpers = #"""
    const clean = (v,n=2000) => String(v || '').replace(/\s+/g,' ').trim().slice(0,n);
    const absolute = (v,base) => { try { const u=new URL(v,base); return u.protocol==='https:' && (u.hostname==='amazon.com'||u.hostname.endsWith('.amazon.com')) ? u.href : ''; } catch(_){return '';} };
    const idFrom = value => (String(value).match(/\b\d{3}-\d{7}-\d{7}\b/)||[])[0] || '';
    const dateFrom = value => {
      const text=clean(value);
      const spanish=text.match(/(?:Pedido realizado|Fecha del pedido|Realizado el)[:\s]*(\d{1,2})\s+de\s+(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre)\s+de\s+(\d{4})/i);
      if(spanish) {
        const months=['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
        return `${spanish[3]}-${String(months.indexOf(spanish[2].toLowerCase())+1).padStart(2,'0')}-${spanish[1].padStart(2,'0')}`;
      }
      const month='(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)';
      const date=`(${month}\\s+\\d{1,2},?\\s+\\d{4}|\\d{4}-\\d{2}-\\d{2})`;
      const matched=text.match(new RegExp('(?:Order placed|Ordered on|Order date)[:\\s]*'+date,'i'));
      return matched ? matched[1].replace(/(\d{1,2})\s+(\d{4})$/,'$1, $2') : '';
    };
    const statusOf = root => {
      const node=root?.querySelector('[data-component="shipmentStatus"] span,.delivery-box__primary-text,.yohtmlc-shipment-status-primaryText,.shipment-status');
      return clean(node?.textContent,200);
    };
    const read = (root,base) => {
      const text=clean(root.innerText || root.textContent,50000);
      const id=idFrom(root.querySelector('[data-component="orderId"]')?.textContent || text);
      const detail=[...root.querySelectorAll('a[href]')].find(a=>/order-details/i.test(a.getAttribute('href')||'') && idFrom(a.getAttribute('href'))===id);
      const onDetail=id && idFrom(new URL(base).searchParams.get('orderID')||new URL(base).searchParams.get('orderId'))===id;
      const detailsURL=detail?absolute(detail.getAttribute('href'),base):onDetail?base:'';
      const seenRows=new Set(),items=[];
      // Both observed desktop layouts: order-history cards and order-detail purchasedItems.
      const titles=root.querySelectorAll('.yohtmlc-product-title a,.yo-enhanced-title a,[data-component="itemTitle"] a');
      for(const a of [...titles].slice(0,100)) {
        const href=a.getAttribute('href')||'';
        const asin=(href.match(/\/(?:dp|gp\/product)\/([A-Z0-9]{10})(?:[/?]|$)/i)||[])[1]||'';
        const name=clean(a.textContent,200);
        const row=a.closest('.item-box,.yo-enhanced-flex-card,.a-fixed-left-grid');
        if(!name||!asin||!row||seenRows.has(row)) continue;
        seenRows.add(row);
        const priceContainer=row.querySelector('[data-component="unitPrice"],.unit-price,.item-price');
        // a-price repeats an accessible price and an aria-hidden visual price. Read exactly one.
        const price=clean((priceContainer?.querySelector('.a-offscreen')||priceContainer)?.textContent,80);
        const qtyText=clean(row.querySelector('[data-component="quantity"]')?.textContent || row.textContent);
        const qty=qtyText.match(/(?:Quantity|Qty|Cantidad)\s*:?\s*(\d+)/i);
        const currency=(price.match(/\b(USD|CAD|EUR|GBP|JPY|CNY|AUD)\b/)||[])[1] || (price.includes('US$')?'USD':/^\$\s*\d/.test(price)?'USD':'');
        const image=row.querySelector('[data-component="itemImage"] img,img');
        let imageURL=''; try { if(image) imageURL=new URL(image.getAttribute('data-a-hires')||image.getAttribute('src')||'',base).href; } catch(_){}
        const shipment=row.closest('[data-component="shipmentsLeftGrid"],.delivery-box');
        const status=statusOf(shipment) || (row.closest('[data-component="cancelled"]') ? 'Cancelled' : '');
        const itemLink=row.querySelector('a[href*="lineItemId="]');
        let lineID='';try {lineID=itemLink?new URL(itemLink.getAttribute('href'),base).searchParams.get('lineItemId')||'':'';} catch(_){}
        items.push({name,asin,price,currency,quantity:qty?Number(qty[1]):1,quantityWasInferred:!qty,imageURL,status,lineID});
      }
      // Retain separate purchase lines for repeated ASINs; never silently drop a shipment.
      for(let i=0;i<items.length;i++) {
        const item=items[i];
        if(items.filter(v=>v.asin===item.asin).length===1) item.lineID='';
        else if(!item.lineID) {
          const signature=JSON.stringify([item.asin,item.name.toLowerCase(),item.price,item.quantity]);
          const occurrence=items.slice(0,i).filter(v=>JSON.stringify([v.asin,v.name.toLowerCase(),v.price,v.quantity])===signature).length;
          item.lineID=`stable:${signature}:${occurrence}`;
        }
      }
      const statuses=[...new Set(items.map(v=>v.status).filter(Boolean))];
      return {id,date:dateFrom(text)||clean(root.querySelector('[data-component="orderDate"]')?.textContent,80),status:statuses.join(' · '),detailsURL,items};
    };
    const detailRoot = doc => doc.querySelector('#orderDetails');
    """#

    /// Returns a JSON array of the orders visible on the current page (at most 20).
    public static let listScript = "(() => {" + helpers + #"""
      if(location.hostname!=='amazon.com'&&!location.hostname.endsWith('.amazon.com')) throw new Error('Open Amazon.com orders first.');
      if(document.querySelector('input[type="password"],#captchacharacters')||/\/ap\/signin/.test(location.pathname)) throw new Error('Finish signing in to Amazon first.');
      const orders=[],seen=new Set();
      for(const node of document.querySelectorAll('.order-card')) {
        const order=read(node,location.href);
        if(order.id&&order.items.length&&!seen.has(order.id)) {seen.add(order.id);orders.push(order);}
      }
      if(!orders.length) {
        const root=detailRoot(document);
        if(root) {const order=read(root,location.href);if(order.id&&order.items.length) orders.push(order);}
      }
      return JSON.stringify(orders.slice(0,20));
    })()
    """#

    /// Distinguishes authentication/verification and a recognized empty history
    /// from an unsupported page. A failed extraction is never the end of history.
    public static let accessScript = #"""
    (() => {
      if (/\/ap\//.test(location.pathname) || document.querySelector('input[type="password"],#captchacharacters,#auth-mfa-otpcode,input[name="otpCode"]')) return 'signIn';
      const text = document.body?.innerText || '';
      if (/\/(your-orders|gp\/your-account)\//.test(location.pathname) && /you have not placed any orders|no orders (?:on|in|found)|no matching orders|no hemos encontrado pedidos/i.test(text)) return 'empty';
      return 'orders';
    })()
    """#

    /// Only exposes pagination links from Amazon's order pager, never arbitrary page links.
    public static let navigationScript = #"""
    (() => {
      const pager = document.querySelector('.a-pagination');
      const safe = node => {
        try {
          const u = new URL(node.getAttribute('href'), location.href);
          return u.origin === location.origin && /\/(your-orders|gp\/your-account|gp\/css)\//.test(u.pathname) ? u.href : null;
        } catch (_) { return null; }
      };
      return JSON.stringify({
        previous: safe(pager?.querySelector('li:first-child:not(.a-disabled) a')),
        next: safe(pager?.querySelector('li.a-last:not(.a-disabled) a')),
        page: pager?.querySelector('.a-selected')?.textContent.trim() || ''
      });
    })()
    """#

    /// Body for `callAsyncJavaScript` with `url` and `orderID` arguments. Fetches the
    /// order-details page in the signed-in session, parses it in a detached document,
    /// and returns one JSON order whose id must equal `orderID`.
    public static let detailScript = helpers + #"""
      const target = new URL(url,location.href);
      if(target.origin!==location.origin || !/order-details/i.test(target.pathname) || idFrom(target.searchParams.get('orderID')||target.searchParams.get('orderId'))!==orderID) throw new Error('Open this order’s details in Amazon and try again.');
      let doc=document;
      if(target.href!==location.href) {
        const controller=new AbortController();(globalThis.chOrderRequests ??= new Set()).add(controller);const timeout=setTimeout(()=>controller.abort(),25000);
        try {
          const response=await fetch(target.href,{credentials:'same-origin',redirect:'follow',signal:controller.signal});
          if(!response.ok || new URL(response.url).origin!==location.origin) throw new Error('Amazon did not return this order.');
          const reader=response.body.getReader();let size=0;const chunks=[];
          while(true) {const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>4000000){await reader.cancel();throw new Error('This order page is too large.');}chunks.push(value);}
          const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
          doc=new DOMParser().parseFromString(new TextDecoder().decode(bytes),'text/html');
        } finally {clearTimeout(timeout);globalThis.chOrderRequests?.delete(controller);}
      }
      if(doc.querySelector('input[type="password"],#captchacharacters')) throw new Error('Amazon needs your attention. Return to the order page.');
      const root=detailRoot(doc);
      if(!root) throw new Error('This order layout could not be read. Open its details in Amazon and try again.');
      const order=read(root,target.href);
      if(order.id!==orderID) throw new Error('Amazon returned a different order. Nothing has been imported.');
      return JSON.stringify(order);
    """#

    /// The order-history page a browser should open first.
    public static let orderHistoryURL = URL(string: "https://www.amazon.com/your-orders/orders")!
}
