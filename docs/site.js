(() => {
  document.documentElement.classList.add('js');

  // Reveal sections as they are reached; IntersectionObserver, no scroll listeners.
  const items=document.querySelectorAll('.reveal');
  if('IntersectionObserver' in window){
    const io=new IntersectionObserver(entries=>entries.forEach(e=>{if(e.isIntersecting){e.target.classList.add('in');io.unobserve(e.target);}}),{rootMargin:'0px 0px -8% 0px',threshold:.12});
    items.forEach(el=>io.observe(el));
  } else items.forEach(el=>el.classList.add('in'));

  // WeChat demo: runs entirely in the browser on sample tasks. No network, model or WeChat.
  const thread=document.getElementById('thread'),form=document.getElementById('compose'),input=document.getElementById('say');
  if(!thread||!form)return;
  const tasks=[
    {n:1,title:'提交 Q4 产品方案',meta:'进行中 60% · 工作',when:'已逾期 1 天',done:false},
    {n:2,title:'和设计确认官网首屏',meta:'等待 · 工作',when:'明天 17:00',done:false},
    {n:3,title:'预约年度体检',meta:'生活',when:'明天 09:30',done:false},
    {n:5,title:'整理周会纪要发给团队',meta:'工作',when:'周五 10:00',done:false}
  ];
  let pending=null,code=0,model='本地 Ollama';
  const reduce=matchMedia('(prefers-reduced-motion: reduce)').matches;
  const wait=ms=>new Promise(r=>setTimeout(r,reduce?0:ms));
  function add(text,me=false){
    const m=document.createElement('div');m.className='msg'+(me?' me':'');m.textContent=text;thread.append(m);
    thread.scrollTop=thread.scrollHeight;
  }
  function list(){
    const open=tasks.filter(t=>!t.done);
    if(!open.length)return '本周的事都处理完了。';
    return `本周还有 ${open.length} 项\n\n`+open.map(t=>`${t.n}、${t.title}\n   ${t.when} · ${t.meta}`).join('\n\n')+'\n\n回复「任务编号 + 操作」，如：任务3改到下周一。';
  }
  // Capture: a day word plus an optional time; whatever remains becomes the title.
  const days=/(今天|明天|后天|大后天|下周[一二三四五六日天]|周[一二三四五六日天]|星期[一二三四五六日天]|\d{1,2}月\d{1,2}[日号])/;
  const clockRe=/([0-9]{1,2}|[一二两三四五六七八九十]{1,3})\s*(?:点|:|：)\s*(半|[0-9]{1,2}|[一二三四五]?十[一二三四五六七八九]?|[一二三四五六七八九])?(?:分)?/;
  function cn(v){
    if(/^\d+$/.test(v))return Number(v);
    const d={'一':1,'二':2,'两':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9};
    if(v==='十')return 10;
    if(v.includes('十')){const [a,b]=v.split('十');return (a?d[a]:1)*10+(b?d[b]:0);}
    return d[v]??0;
  }
  function capture(text){
    if(!days.test(text)||/还有什么|有哪些|有什么|查|安排|任务\s*\d/.test(text))return null;
    const day=text.match(days)[1].replace('星期','周');
    const part=(text.match(/(上午|中午|下午|晚上|早上)/)||[])[1]||'';
    const clock=text.match(clockRe);
    let h=clock?cn(clock[1]):(part==='下午'?15:part==='晚上'?20:9),m=0;
    if(clock&&clock[2])m=clock[2]==='半'?30:cn(clock[2]);
    if(clock&&(part==='下午'||part==='晚上')&&h<12)h+=12;
    let title=text.replace(days,'').replace(/(上午|中午|下午|晚上|早上)/,'').replace(clockRe,'');
    title=title.replace(/[，。！!？?]/g,'').trim().replace(/^(提醒我|记得|帮我记一下|记一下|要|前|之前|的)+/,'').trim();
    if(!title)return null;
    const group=/方案|报告|会|客户|设计|周报|合同|评审/.test(title)?'工作':/医|妈|爸|体检|猫|狗|买|快递|房租|电话/.test(title)?'生活':'收件箱';
    return {title,when:`${day} ${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}`,group};
  }
  function reply(text){
    const confirm=text.match(/^(确认|取消)\s*(\d+)$/),move=text.match(/任务\s*(\d+).*改到(.+)$/),done=text.match(/任务\s*(\d+)\s*(?:标记)?完成/);
    if(confirm){
      if(!pending||Number(confirm[2])!==pending.code)return '没有找到这条待确认的操作。';
      const p=pending;pending=null;
      if(confirm[1]==='取消')return '已取消，任务没有改动。';
      if(p.kind==='add'){
        const n=Math.max(...tasks.map(t=>t.n))+1;
        tasks.push({n,title:p.item.title,meta:p.item.group,when:p.item.when,done:false});
        return `已记下任务${n}\n\n${p.item.title}\n${p.item.when} · ${p.item.group}\n\n已同步到 Mac 和 iPhone 的提醒事项，到点会提醒你。`;
      }
      if(p.kind==='move'){p.task.when=p.when;return `已调整任务${p.task.n}\n\n${p.task.title}\n${p.when}`;}
      p.task.done=true;return `已完成任务${p.task.n}\n\n${p.task.title}\n又少一件惦记的事。`;
    }
    if(move||done){
      const n=Number((move||done)[1]),task=tasks.find(t=>t.n===n);
      if(!task)return `没有找到任务${n}，先发“这周还有什么”核对编号。`;
      if(done&&task.done)return `任务${n}已经完成了。`;
      code+=1;
      if(move){const when=move[2].replace(/[。！!]$/,'').trim()||'下周一';pending={code,kind:'move',task,when:when.includes('下周一')?'下周一 09:30':when};return `待确认 ${code}\n\n${task.title}\n改到 ${pending.when}\n\n回复「确认${code}」执行，或「取消${code}」。`;}
      pending={code,kind:'done',task};return `待确认 ${code}\n\n标记完成：${task.title}\n\n回复「确认${code}」执行，或「取消${code}」。`;
    }
    // Dated commands always ask for a short confirmation first, as in the app.
    const item=capture(text);
    if(item){
      code+=1;pending={code,kind:'add',item};
      return `待确认 ${code}\n\n新增：${item.title}\n${item.when} · ${item.group}\n\n回复「确认${code}」记下。`;
    }
    if(/模型/.test(text)){
      if(/切换|换成|改用/.test(text)){model=/云/.test(text)?'云端模型':'本地 Ollama';return `已切换到 ${model}。`;}
      return `当前模型：${model}\n\n可说：切换到云端模型。`;
    }
    if(/待办|还有什么|这周|今天|任务/.test(text))return list();
    return '这是网页里的本地演示，能听懂这几类：\n\n周四上午十点约牙医\n这周还有什么要做的？\n任务3改到下周一\n任务1标记完成\n\n真实的记事喵用你配置的模型理解任意说法。';
  }
  let busy=false;
  async function send(text){
    text=text.trim();if(!text||busy)return;busy=true;add(text,true);input.value='';
    await wait(420);add(reply(text));busy=false;
    // Offer the confirmation reply as the next suggestion so the flow is one click.
    const confirmButton=document.getElementById('confirm-suggest');
    if(pending){
      const b=confirmButton||Object.assign(document.createElement('button'),{type:'button',id:'confirm-suggest'});
      b.textContent=`确认${pending.code}`;b.dataset.say=`确认${pending.code}`;document.getElementById('suggest').prepend(b);
    } else confirmButton?.remove();
  }
  form.addEventListener('submit',e=>{e.preventDefault();send(input.value);});
  document.getElementById('suggest').addEventListener('click',e=>{const b=e.target.closest('button');if(b)send(b.dataset.say);});
  // Open with one capture so the panel shows the main use before anyone types.
  const first='明天下午三点交季度报告';add(first,true);add(reply(first));add('确认1',true);add(reply('确认1'));
})();
