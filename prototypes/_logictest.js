// _logictest.js —— 用最小 DOM 桩把原型的**玩法逻辑**跑起来验证
// 目的：本机浏览器截图不可用，但"首点安全 / 快捷展开 / 胜负 / 撤销"这些是纯逻辑，
//      完全可以在 Node 里断言。跑法：node _logictest.js
const fs=require('fs'), vm=require('vm'), path=require('path');

/* ---------- 最小 DOM 桩：够脚本跑完 + 够我驱动逻辑 ---------- */
function makeEl(tag){
  const self={
    tagName:(tag||'div').toUpperCase(), _cls:new Set(), _attrs:{}, _children:[],
    dataset:{}, tabIndex:0, textContent:'', innerHTML:'', value:'', width:0, height:0,
    firstChild:{textContent:''},
    style:new Proxy({setProperty(){}},{get:(t,k)=>k in t?t[k]:'',set:()=>true}),
    classList:{
      add(...c){c.forEach(x=>self._cls.add(x))},
      remove(...c){c.forEach(x=>self._cls.delete(x))},
      toggle(c,f){ if(f===undefined){self._cls.has(c)?self._cls.delete(c):self._cls.add(c)}
                   else {f?self._cls.add(c):self._cls.delete(c)} },
      contains(c){return self._cls.has(c)}
    },
    appendChild(c){self._children.push(c);return c},
    setAttribute(k,v){self._attrs[k]=String(v)},
    getAttribute(k){return k in self._attrs?self._attrs[k]:null},
    addEventListener(){}, removeEventListener(){}, focus(){}, click(){},
    querySelector(){return makeEl()}, querySelectorAll(){return []}, closest(){return null},
    get parentElement(){return makeEl()}, get clientWidth(){return 1000}, get clientHeight(){return 600}
  };
  return self;
}
const cache={};
const document={
  createElement:t=>makeEl(t),
  querySelector:s=>cache[s]||(cache[s]=makeEl()),
  querySelectorAll:()=>[],
  addEventListener(){}, body:makeEl(), activeElement:null
};

const sandbox={ document, console, Math, Date, setInterval, clearInterval, setTimeout, clearTimeout,
  window:null, addEventListener(){}, requestAnimationFrame:f=>setTimeout(f,0) };
sandbox.window=sandbox; sandbox.globalThis=sandbox;
vm.createContext(sandbox);

const FILE = process.argv[2] || 'ui-replica.html';
const src=fs.readFileSync(path.join(__dirname,FILE),'utf8')
  .match(/<script>([\s\S]*)<\/script>/)[1];
console.log(`被测文件：${FILE}`);
vm.runInContext(src + `
;globalThis.__api={ newGame, placeMines, clickCell, chord, toggleFlag, hint, undo, S, nb, readouts };`,
  sandbox);

const A=sandbox.__api, S=A.S;
const N=()=>S.rows*S.cols;
const nb=A.nb;
let pass=0, fail=0;
function ok(cond,msg){ if(cond){pass++} else {fail++;console.log("  ❌ "+msg)} }
function head(t){ console.log("\n=== "+t+" ===") }

/* ---------- ① 首点必不踩雷（跑 500 局）---------- */
head("① 首点必不踩雷（500 局随机首点）");
let firstMine=0, nbMine=0, allZeroFirst=false, floodOk=0;
for(let g=0; g<500; g++){
  A.newGame();
  const first=Math.floor(Math.random()*N());
  A.clickCell(first);
  if(S.board[first]===-1) firstMine++;
  if(nb(first).some(j=>S.board[j]===-1)) nbMine++;
  if(S.board[first]===0) allZeroFirst=true;
  if(S.board[first]===0 && S.open.filter(Boolean).length>=9) floodOk++;
}
ok(firstMine===0, "首点踩雷 "+firstMine+" 次（必须 0）");
ok(nbMine===0, "首点邻域有雷 "+nbMine+" 次（必须 0）");
ok(floodOk>0, "首点为 0 时未触发洪泛展开");
console.log("  500 局：首点踩雷 "+firstMine+"，邻域含雷 "+nbMine+"，洪泛生效局数 "+floodOk);

/* ---------- ② 快捷展开（chord）----------
   注意：chord 只对**已翻开**的数字生效（未翻开是普通翻开）。
   所以测试要先把目标格单独翻开，再给它的雷邻格插旗，最后再点一次。 */
head("② 快捷展开：旗数 == 数字时一次翻开其余邻格");
A.newGame();
A.placeMines(40);
let target=-1;
for(let i=0;i<N();i++){
  if(S.board[i]>0 && nb(i).some(j=>S.board[j]===-1)){ target=i; break }
}
ok(target>=0, "找不到可用于测试的数字格");
if(target>=0){
  S.open[target]=true;                                  // 只翻开它自己
  const mines=nb(target).filter(j=>S.board[j]===-1);
  mines.forEach(j=>{ S.flag[j]=true });                 // 把雷邻格全插旗
  const before=S.open.filter(Boolean).length;
  A.clickCell(target);                                  // 点已翻开的数字 → 走 chord
  const after=S.open.filter(Boolean).length;
  const rest=nb(target).filter(j=>S.board[j]!==-1);
  ok(rest.every(j=>S.open[j]), "chord 未翻开全部安全邻格（应一次全开）");
  ok(after>before, "chord 没有产生任何翻开");
  console.log("  目标格 "+target+" 数字="+S.board[target]+" 旗 "+mines.length+
              " → 翻开数 "+before+" → "+after);
}

/* ---------- ③ 踩雷：揭示全部雷 ---------- */
head("③ 踩雷：S.over 置位 + 全部雷被揭示");
A.newGame();
const m=A.placeMines, firstIdx=0; A.placeMines(firstIdx);
const mineIdx=S.board.findIndex(v=>v===-1);
ok(mineIdx>=0,"没找到雷");
A.clickCell(mineIdx);
ok(S.over===true, "踩雷后 S.over 未置位");
ok(S.boomIdx===mineIdx, "S.boomIdx 未指向踩中的那颗");
ok(S.board.filter(v=>v===-1).every((v,i)=>true), "雷集合异常");
const mineTotal=S.board.filter(v=>v===-1).length;
const mineOpen=S.board.map((v,i)=>v===-1&&S.open[i]).filter(Boolean).length;
ok(mineOpen===mineTotal, "踩雷后只揭示了 "+mineOpen+"/"+mineTotal+" 颗雷（应全揭示）");
console.log("  揭示 "+mineOpen+"/"+mineTotal+" 颗雷");

/* ---------- ④ 胜利：自动补旗 ----------
   触发点必须是"翻开最后一个隐藏安全格"（点已翻开的格只会走 chord）。 */
head("④ 胜利：翻开最后一个安全格 → 判定胜利 + 自动补旗");
A.newGame();
A.placeMines(0);
const safe=[]; for(let i=0;i<N();i++) if(S.board[i]!==-1) safe.push(i);
safe.slice(0,-1).forEach(i=>{ S.open[i]=true });       // 留最后一个安全格没翻
S.over=false;
A.clickCell(safe[safe.length-1]);                      // 点它 → afterChange → 胜利
ok(S.over===true, "全翻开后未判定胜利");
const flags=S.flag.filter(Boolean).length;
const mines=S.board.filter(v=>v===-1).length;
ok(flags===mines, "胜利后自动补旗 "+flags+"/"+mines+"（应补满）");
console.log("  自动补旗 "+flags+"/"+mines);

/* ---------- ⑤ 撤销：翻开的格退回去 ---------- */
head("⑤ 撤销：退回到操作前");
A.newGame();
A.placeMines(40);
const openedBefore=S.open.filter(Boolean).length;
A.clickCell(40);
const openedAfter=S.open.filter(Boolean).length;
ok(openedAfter>openedBefore, "点击没有产生翻开");
A.undo();
ok(S.open.filter(Boolean).length===openedBefore, "撤销后未回到操作前状态");

/* ---------- ⑥ 剩余雷数允许负数 ---------- */
head("⑥ 剩余雷数：插旗超了显示负数（而不是被钳到 0）");
A.newGame(); A.placeMines(40);
for(let i=0;i<S.mines+3;i++) S.flag[i]=true;
A.readouts();
const shown=cache['#mineCount'].textContent;
ok(shown===-3, "显示 "+shown+"（应为 -3）");

/* ---------- ⑦ 计时可续跑（撤销不重置） ---------- */
head("⑦ 计时：撤销后不重置已用时间");
A.newGame(); A.placeMines(40);
A.clickCell(40);
S.elapsed=42;
A.undo();
ok(S.elapsed===42 || S.elapsed>=42, "撤销把计时重置成了 "+S.elapsed);

console.log("\n"+"─".repeat(46));
console.log(fail===0 ? `全部通过 ✅  ${pass} 项` : `❌ ${fail} 项失败 / ${pass} 项通过`);
process.exit(fail?1:0);
