// A minimal public suffix list, vendored (no network at runtime), for one
// purpose: the registrable domain ("eTLD+1") of a host, which equivalent
// domains are matched on (domains.mjs). Every TLD is a suffix; on top of that,
// these multi-label ICANN suffixes (co.uk, com.au, net.cn, ...) and the private
// suffixes of the big hosting platforms (github.io, myshopify.com, ...) where
// every customer gets their own subdomain. Generated from the Public Suffix
// List (via tldts) on 2026-11-05 by probing common second-level labels of
// every ccTLD; checked against Bitwarden's global equivalent domains.
//
// A suffix missing here can only make a registrable domain too short
// ("x.foo.zz" -> "foo.zz" where the real answer is "x.foo.zz"). That is safe
// for equivalence: a group never lists a public suffix (domains.mjs drops a
// listed one when it is here), and a too-short domain matches no group.

/** Multi-label public suffixes. */
export const SUFFIXES = new Set(`
    com.ac net.ac org.ac edu.ac gov.ac mil.ac co.ae net.ae org.ae gov.ae ac.ae mil.ae sch.ae com.af net.af
    org.af edu.af gov.af co.ag com.ag net.ag org.ag nom.ag com.ai net.ai org.ai com.al net.al org.al edu.al
    gov.al mil.al co.am com.am net.am org.am co.ao org.ao edu.ao gov.ao ed.ao com.ar net.ar org.ar edu.ar
    gov.ar gob.ar mil.ar int.ar gov.as co.at ac.at or.at com.au net.au org.au edu.au gov.au sa.au asn.au id.au
    com.aw co.az com.az net.az org.az edu.az gov.az mil.az int.az biz.az info.az name.az pro.az com.ba net.ba
    org.ba edu.ba gov.ba mil.ba co.bb com.bb net.bb org.bb edu.bb gov.bb biz.bb info.bb ac.be gov.bf com.bh
    net.bh org.bh edu.bh gov.bh co.bi com.bi org.bi edu.bi or.bi co.bj com.bj net.bj org.bj edu.bj info.bj
    com.bm net.bm org.bm edu.bm gov.bm com.bn net.bn org.bn edu.bn gov.bn com.bo net.bo org.bo edu.bo gob.bo
    mil.bo int.bo info.bo web.bo blog.bo com.br net.br org.br edu.br gov.br mil.br ind.br pro.br med.br art.br
    blog.br com.bs net.bs org.bs edu.bs gov.bs com.bt net.bt org.bt edu.bt gov.bt co.bw net.bw org.bw gov.bw
    ac.bw com.by gov.by mil.by co.bz com.bz net.bz org.bz edu.bz gov.bz pe.ca gov.cd co.ci com.ci net.ci
    org.ci edu.ci ac.ci or.ci go.ci int.ci gouv.ci asso.ci ed.ci co.cl gov.cl gob.cl mil.cl co.cm com.cm
    net.cm gov.cm com.cn net.cn org.cn edu.cn gov.cn ac.cn mil.cn com.co net.co org.co edu.co gov.co mil.co
    nom.co co.cr ac.cr or.cr go.cr ed.cr sa.cr fi.cr com.cu net.cu org.cu edu.cu gob.cu com.cv net.cv org.cv
    edu.cv int.cv id.cv com.cw net.cw org.cw edu.cw gov.cx com.cy net.cy org.cy gov.cy ac.cy mil.cy ltd.cy
    biz.cy tm.cy pro.cy co.dm com.dm net.dm org.dm edu.dm gov.dm com.do net.do org.do edu.do gov.do gob.do
    mil.do web.do art.do com.dz net.dz org.dz edu.dz gov.dz asso.dz tm.dz art.dz com.ec net.ec org.ec edu.ec
    gov.ec gob.ec mil.ec info.ec k12.ec pro.ec med.ec fin.ec com.ee org.ee edu.ee gov.ee med.ee com.eg net.eg
    org.eg edu.eg gov.eg ac.eg mil.eg me.eg info.eg name.eg com.es org.es edu.es gob.es nom.es com.et net.et
    org.et edu.et gov.et biz.et info.et name.et com.fj net.fj org.fj gov.fj ac.fj mil.fj biz.fj info.fj
    name.fj pro.fj com.fm net.fm org.fm edu.fm com.fr nom.fr gouv.fr asso.fr tm.fr edu.gd gov.gd com.ge net.ge
    org.ge edu.ge gov.ge school.ge co.gg net.gg org.gg com.gh org.gh edu.gh gov.gh mil.gh com.gi org.gi edu.gi
    gov.gi ltd.gi co.gl com.gl net.gl org.gl edu.gl com.gn net.gn org.gn edu.gn gov.gn ac.gn com.gp net.gp
    org.gp edu.gp asso.gp com.gr net.gr org.gr edu.gr gov.gr com.gt net.gt org.gt edu.gt gob.gt mil.gt ind.gt
    com.gu net.gu org.gu edu.gu gov.gu info.gu web.gu co.gy com.gy net.gy org.gy edu.gy gov.gy com.hk net.hk
    org.hk edu.hk gov.hk idv.hk com.hn net.hn org.hn edu.hn gob.hn mil.hn com.hr name.hr com.ht net.ht org.ht
    edu.ht firm.ht info.ht gouv.ht asso.ht pro.ht med.ht art.ht co.hu org.hu info.hu tm.hu co.id net.id ac.id
    or.id go.id mil.id sch.id biz.id web.id gov.ie co.il net.il org.il gov.il ac.il k12.il muni.il co.im
    com.im net.im org.im ac.im co.in com.in net.in org.in edu.in gov.in ac.in mil.in int.in me.in gen.in
    firm.in ind.in res.in biz.in info.in pro.in co.io com.io net.io org.io edu.io gov.io mil.io nom.io com.iq
    net.iq org.iq edu.iq gov.iq mil.iq co.ir net.ir org.ir gov.ir ac.ir sch.ir id.ir co.it edu.it gov.it or.it
    go.it me.it av.it gr.it re.it pe.it sa.it fi.it co.je net.je org.je com.jo net.jo org.jo edu.jo gov.jo
    mil.jo sch.jo per.jo co.jp ac.jp or.jp ne.jp go.jp ad.jp ed.jp lg.jp gr.jp co.ke ac.ke or.ke ne.ke go.ke
    me.ke info.ke com.kg net.kg org.kg edu.kg gov.kg mil.kg com.ki net.ki org.ki edu.ki gov.ki biz.ki info.ki
    com.km org.km edu.km gov.km mil.km nom.km gouv.km asso.km tm.km net.kn org.kn edu.kn gov.kn com.kp org.kp
    edu.kp gov.kp co.kr ac.kr or.kr ne.kr go.kr mil.kr me.kr re.kr pe.kr hs.kr com.kw net.kw org.kw edu.kw
    gov.kw ind.kw com.ky net.ky org.ky edu.ky com.kz net.kz org.kz edu.kz gov.kz mil.kz com.la net.la org.la
    edu.la gov.la int.la per.la info.la com.lb net.lb org.lb edu.lb gov.lb co.lc com.lc net.lc org.lc edu.lc
    gov.lc com.lk net.lk org.lk edu.lk gov.lk ac.lk int.lk ltd.lk sch.lk web.lk com.lr net.lr org.lr edu.lr
    gov.lr co.ls net.ls org.ls edu.ls gov.ls ac.ls biz.ls info.ls gov.lt com.lv net.lv org.lv edu.lv gov.lv
    mil.lv asn.lv id.lv com.ly net.ly org.ly edu.ly gov.ly plc.ly sch.ly med.ly id.ly co.ma net.ma org.ma
    gov.ma ac.ma asso.mc tm.mc co.me net.me org.me edu.me gov.me ac.me co.mg com.mg org.mg edu.mg gov.mg
    mil.mg nom.mg com.mk net.mk org.mk edu.mk gov.mk name.mk com.ml net.ml org.ml edu.ml gov.ml ac.ml info.ml
    gouv.ml asso.ml art.ml org.mn edu.mn gov.mn com.mo net.mo org.mo edu.mo gov.mo gov.mr com.ms net.ms org.ms
    edu.ms gov.ms com.mt net.mt org.mt edu.mt co.mu com.mu net.mu org.mu gov.mu ac.mu or.mu com.mv net.mv
    org.mv edu.mv gov.mv mil.mv int.mv biz.mv info.mv name.mv pro.mv co.mw com.mw net.mw org.mw edu.mw gov.mw
    ac.mw int.mw biz.mw com.mx net.mx org.mx edu.mx gob.mx com.my net.my org.my edu.my gov.my mil.my biz.my
    name.my co.mz net.mz org.mz edu.mz gov.mz ac.mz mil.mz co.na com.na net.na org.na gov.na nom.nc asso.nc
    com.nf net.nf firm.nf per.nf info.nf web.nf com.ng net.ng org.ng edu.ng gov.ng mil.ng sch.ng name.ng co.ni
    com.ni net.ni org.ni edu.ni ac.ni gob.ni mil.ni int.ni nom.ni biz.ni info.ni web.ni in.ni mil.no tm.no
    com.nr net.nr org.nr edu.nr gov.nr biz.nr info.nr co.nz net.nz org.nz ac.nz mil.nz govt.nz gen.nz kiwi.nz
    school.nz geek.nz maori.nz co.om com.om net.om org.om edu.om gov.om pro.om med.om com.pa net.pa org.pa
    edu.pa ac.pa gob.pa nom.pa med.pa com.pe net.pe org.pe edu.pe gob.pe mil.pe nom.pe com.pf org.pf edu.pf
    com.ph net.ph org.ph edu.ph gov.ph mil.ph com.pk net.pk org.pk edu.pk gov.pk ac.pk gob.pk biz.pk web.pk
    com.pl net.pl org.pl edu.pl gov.pl mil.pl nom.pl biz.pl info.pl tm.pl co.pn net.pn org.pn edu.pn gov.pn
    com.pr net.pr org.pr edu.pr gov.pr ac.pr biz.pr info.pr name.pr pro.pr com.ps net.ps org.ps edu.ps gov.ps
    com.pt net.pt org.pt edu.pt gov.pt int.pt gov.pw com.py net.py org.py edu.py gov.py mil.py com.qa net.qa
    org.qa edu.qa gov.qa mil.qa sch.qa name.qa com.re asso.re com.ro org.ro nom.ro firm.ro info.ro tm.ro co.rs
    org.rs edu.rs gov.rs ac.rs in.rs co.rw net.rw org.rw gov.rw ac.rw mil.rw com.sa net.sa org.sa edu.sa
    gov.sa sch.sa med.sa com.sb net.sb org.sb edu.sb gov.sb com.sc net.sc org.sc edu.sc gov.sc com.sd net.sd
    org.sd edu.sd gov.sd info.sd med.sd org.se ac.se tm.se com.sg net.sg org.sg edu.sg gov.sg com.sh net.sh
    org.sh gov.sh mil.sh com.sl net.sl org.sl edu.sl gov.sl com.sn org.sn edu.sn gouv.sn art.sn com.so net.so
    org.so edu.so gov.so me.so co.st com.st net.st org.st edu.st mil.st com.sv org.sv edu.sv gob.sv gov.sx
    com.sy net.sy org.sy edu.sy gov.sy mil.sy co.sz org.sz ac.sz co.th net.th ac.th or.th go.th in.th co.tj
    com.tj net.tj org.tj edu.tj gov.tj ac.tj go.tj mil.tj int.tj biz.tj name.tj web.tj gov.tl co.tm com.tm
    net.tm org.tm edu.tm gov.tm mil.tm nom.tm com.tn net.tn org.tn gov.tn ind.tn info.tn fin.tn com.to net.to
    org.to edu.to gov.to mil.to com.tr net.tr org.tr edu.tr gov.tr mil.tr gen.tr biz.tr info.tr name.tr web.tr
    k12.tr bbs.tr av.tr bel.tr tel.tr co.tt com.tt net.tt org.tt edu.tt gov.tt mil.tt biz.tt info.tt name.tt
    pro.tt com.tw net.tw org.tw edu.tw gov.tw mil.tw idv.tw co.tz ac.tz or.tz ne.tz go.tz mil.tz me.tz info.tz
    com.ua net.ua org.ua edu.ua gov.ua in.ua lg.ua co.ug com.ug org.ug edu.ug gov.ug ac.ug or.ug ne.ug go.ug
    mil.ug co.uk net.uk org.uk gov.uk ac.uk ltd.uk plc.uk me.uk nhs.uk police.uk co.us or.us ne.us me.us in.us
    id.us com.uy net.uy org.uy edu.uy mil.uy co.uz com.uz net.uz org.uz com.vc net.vc org.vc edu.vc gov.vc
    mil.vc co.ve com.ve net.ve org.ve edu.ve gov.ve gob.ve mil.ve int.ve nom.ve firm.ve info.ve web.ve edu.vg
    co.vi com.vi net.vi org.vi k12.vi com.vn net.vn org.vn edu.vn gov.vn ac.vn int.vn biz.vn info.vn name.vn
    pro.vn id.vn com.vu net.vu org.vu edu.vu com.ws net.ws org.ws edu.ws gov.ws com.ye net.ye org.ye edu.ye
    gov.ye mil.ye co.za net.za org.za edu.za gov.za ac.za mil.za nom.za school.za web.za tm.za co.zm com.zm
    net.zm org.zm edu.zm gov.zm ac.zm mil.zm sch.zm biz.zm info.zm co.zw org.zw gov.zw ac.zw mil.zw
    github.io githubusercontent.com gitlab.io herokuapp.com blogspot.com appspot.com cloudfront.net
    azurewebsites.net netlify.app vercel.app pages.dev workers.dev myshopify.com firebaseapp.com web.app
    s3.amazonaws.com elasticbeanstalk.com azurestaticapps.net cloudapp.net trafficmanager.net onrender.com
    fly.dev glitch.me repl.co replit.dev ngrok.io ngrok-free.app duckdns.org dyndns.org no-ip.org wixsite.com
    readthedocs.io now.sh bitbucket.io codeberg.page translate.goog withgoogle.com cloudfunctions.net
    webflow.io framer.app carrd.co notion.site
`.trim().split(/\s+/));

/** TLDs where every second-level label is a public suffix (PSL "*.ck" rules). */
export const WILDCARD_TLDS = new Set(['bd', 'ck', 'er', 'fk', 'jm', 'kh', 'mm', 'np', 'pg']);
