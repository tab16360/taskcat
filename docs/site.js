(() => {
  const $ = id => document.getElementById(id);
  const input = $('demo-input'), send = $('demo-send');
  const tasks = [
    {title:'整理周会分享材料',meta:'工作 · 明天 10:00',done:false},
    {title:'看一看周末的展览',meta:'生活 · 周六 14:00',done:false},
    {title:'给猫咪补充口粮',meta:'收件箱',done:false}
  ];
  let busy = false;
  let signalTimer;
  const motionDelay=ms=>new Promise(resolve=>setTimeout(resolve,matchMedia('(prefers-reduced-motion: reduce)').matches?0:ms));
  function signal(text) {
    clearTimeout(signalTimer);$('bridge-label').textContent=text;$('linked-demo').classList.add('syncing');
    signalTimer=setTimeout(()=>$('linked-demo').classList.remove('syncing'),1800);
  }
  const examples = {
    add: {input:'明晚八点提醒我读书', feedback:'已新增「读书」· 明天 20:00（演示时间）'},
    reschedule: {input:'周会材料改到周五下午', feedback:'已将「整理周会分享材料」改到周五 15:00（演示时间，实际修改前可核对）'},
    complete: {input:'猫粮买好了，标记完成', feedback:'已完成「给猫咪补充口粮」。又少一件惦记的事。'}
  };
  const update = () => {send.disabled = busy || wxBusy || !input.value.trim();};
  const render = changed => {
    $('demo-tasks').replaceChildren(...tasks.map((task,i) => {
      const row = document.createElement('div');row.className = `task${task.done?' done':''}${i===changed?' changed':''}`;
      const check = document.createElement('span');check.className='task-check';
      const content = document.createElement('div'), title = document.createElement('strong'), meta = document.createElement('small');
      title.textContent=task.title;meta.textContent=task.meta;content.append(title,meta);
      const status = document.createElement('span');status.className='status';status.textContent=task.done?'已完成':'待办';
      row.append(check,content,status);
      check.setAttribute('role','button');check.setAttribute('tabindex','0');check.setAttribute('aria-label',(task.done?'重新打开：':'完成：')+task.title);
      const toggle=()=>{if(busy || wxBusy)return;task.done=!task.done;render(i);signal('Mac 面板已更新 · 微信查询可看到变化');$('demo-feedback').textContent='已在 Mac 演示面板'+(task.done?'完成':'重新打开')+'「'+task.title+'」';};
      check.addEventListener('click',toggle);check.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();toggle();}});
      return row;
    }));
    $('demo-count').textContent=tasks.filter(t=>!t.done).length;
    if(Number.isInteger(changed))requestAnimationFrame(()=>{
      const list=$('demo-tasks'),row=list.children[changed];if(!row)return;
      const bounds=list.getBoundingClientRect(),target=row.getBoundingClientRect();
      if(target.bottom>bounds.bottom)list.scrollTop+=target.bottom-bounds.bottom;
      else if(target.top<bounds.top)list.scrollTop-=bounds.top-target.top;
    });
  };
  async function run(key) {
    if (busy || wxBusy) return;
    const example=examples[key];if(!example)return;
    busy=true;input.value=example.input;update();$('thinking').hidden=false;
    if($('composer').hidden){$('composer').hidden=false;$('collapse').setAttribute('aria-expanded','true');$('collapse').textContent='⌃';}
    await new Promise(resolve=>setTimeout(resolve,matchMedia('(prefers-reduced-motion: reduce)').matches?0:850));
    let changed=0;
    if(key==='add'){changed=tasks.findIndex(t=>t.title==='读书');if(changed<0){tasks.push({title:'读书',meta:'收件箱 · 明天 20:00',done:false});changed=tasks.length-1;}}
    if(key==='reschedule')tasks[0].meta='工作 · 周五 15:00';
    if(key==='complete'){tasks[2].done=true;changed=2;}
    render(changed);$('thinking').hidden=true;$('demo-feedback').textContent=example.feedback;input.value='';busy=false;update();signal('Mac 面板已更新 · 微信查询可看到变化');
  }
  document.querySelectorAll('[data-example]').forEach(button=>button.addEventListener('click',()=>run(button.dataset.example)));
  input.addEventListener('input',update);
  const submit=()=>{const key=Object.keys(examples).find(k=>examples[k].input===input.value.trim());if(key)run(key);else $('demo-feedback').textContent='这是浏览器本地示例。请点击下方任一句示例体验；不会把输入发送给模型。';};
  send.addEventListener('click',submit);input.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();if(!send.disabled)submit();}});
  $('theme-toggle').addEventListener('click',()=>{$('demo-app').classList.toggle('dark');$('theme-toggle').setAttribute('aria-label',$('demo-app').classList.contains('dark')?'切换浅色演示':'切换深色演示');});
  $('collapse').addEventListener('click',()=>{if(busy)return;const collapsed=!$('composer').hidden;$('composer').hidden=collapsed;$('collapse').setAttribute('aria-expanded',String(!collapsed));$('collapse').textContent=collapsed?'⌄':'⌃';});

  // Shared synthetic task state: no network, login, real messaging or AI call.
  const thread=$('wx-messages'), wxInput=$('wx-input'), wxSend=$('wx-send');
  let wxPending=null, wxCode=0, wxModel='云端模型 · 示例配置',wxBusy=false;
  const wxUpdate=()=>{wxSend.disabled=wxBusy || busy || !wxInput.value.trim();$('wx-confirm').disabled=wxBusy || busy;update();};
  function appendMessage(text,outgoing=false) {
    const row=document.createElement('div');row.className='wechat-message'+(outgoing?' outgoing':'');
    const avatar=document.createElement('span');avatar.className='wx-avatar';avatar.setAttribute('aria-hidden','true');
    if(outgoing)avatar.textContent='我';
    else {const image=document.createElement('img');image.src='assets/taskcat.png';image.alt='';image.width=26;image.height=26;avatar.append(image);}
    const bubble=document.createElement('div');bubble.className='wx-bubble';bubble.textContent=text;
    row.append(avatar,bubble);thread.append(row);
    thread.scrollTop=outgoing ? thread.scrollHeight : row.offsetTop-thread.offsetTop;
  }
  function listText() {
    const active=tasks.map((task,index)=>({task,number:index+1})).filter(item=>!item.task.done);
    return `当前有 ${active.length} 个待办\n\n`+active.map(({task,number})=>`${number}、${task.title}\n   ${task.meta}`).join('\n\n')+`\n\n回复「任务编号 + 操作」，如：任务${active[0]?.number ?? 1}标记完成。`;
  }
  function setPending(value) {
    wxPending=value;$('wx-confirm').hidden=!value;
    $('stage-pending').hidden=!value;
    if(value){
      const verb=value.kind==='add'?'新增任务':value.kind==='reschedule'?'调整时间':'标记完成';
      $('wx-confirm').textContent='确认'+value.code+' · '+verb;
      $('pending-label').textContent='待确认'+value.code+' · '+verb;
    }
  }
  async function wechat(text) {
    text=text.trim();if(!text || wxBusy || busy)return;wxBusy=true;appendMessage(text,true);wxInput.value='';wxUpdate();
    signal('微信发来一句话 · 记事喵正在整理');
    $('thinking').hidden=false;await motionDelay(600);$('thinking').hidden=true;
    let reply;
    const confirmation=text.match(/^(确认|取消)\s*(\d+)$/), completion=text.match(/任务\s*(\d+)\s*(?:标记)?完成/),reschedule=text.match(/任务\s*(\d+).*改到/);
    if(confirmation) {
      if(!wxPending || Number(confirmation[2])!==wxPending.code)reply='没有找到这条待确认操作。请先选择一项任务，再核对短编号。';
      else if(confirmation[1]==='取消'){setPending(null);reply='已取消，示例任务未修改。';}
      else {
        const pending=wxPending;let index=pending.index;
        if(pending.kind==='add'){index=tasks.length;tasks.push({title:'读书',meta:'收件箱 · 明天 20:00',done:false});reply=`已新增任务${index+1}\n\n读书\n明天 20:00（演示时间）`;}
        else if(pending.kind==='reschedule'){tasks[index].meta='工作 · 周五 15:00';reply=`已调整任务${index+1}\n\n${tasks[index].title}\n周五 15:00（演示时间）`;}
        else {tasks[index].done=true;reply=`已完成任务${index+1}\n\n${tasks[index].title}\n已完成`;}
        setPending(null);render(index);signal('微信操作已确认 · Mac 待办同步更新');$('demo-feedback').textContent='来自微信的操作已更新同一份示例待办。';
      }
    } else if(/读书/.test(text) && /明|提醒|新增/.test(text)) {
      const code=++wxCode;setPending({code,kind:'add'});reply=`待确认${code}\n\n新增「读书」\n明天 20:00（演示时间）\n\n回复「确认${code}」安排。`;signal('微信提出新安排 · 两端显示待确认');
    } else if(reschedule) {
      const index=Number(reschedule[1])-1,task=tasks[index];
      if(!task)reply='没有找到这个任务编号，请先查看待办。';
      else {const code=++wxCode;setPending({code,index,kind:'reschedule'});reply=`待确认${code}\n\n${task.title}\n改为周五 15:00（演示时间）\n\n回复「确认${code}」调整。`;signal('微信提出改期 · Mac 显示待确认');}
    } else if(completion) {
      const index=Number(completion[1])-1,task=tasks[index];
      if(!task)reply='没有找到这个任务编号。请先发送“查看待办”。';
      else if(task.done)reply=`任务${index+1}已经完成，未重复操作。`;
      else {const code=++wxCode;setPending({code,index});reply=`待确认${code}\n\n标记完成任务${index+1}\n${task.title}\n\n回复「确认${code}」执行，或「取消${code}」。`;}
    } else if(/切换.*(?:本地|模型1)/.test(text)) {wxModel='本地 Ollama · 示例配置';$('demo-model').textContent='◉ 本地 Ollama⌄';reply='已切换到本地模型\n\n本地 Ollama · 示例配置\n\n可回复：当前模型。';}
    else if(/切换.*(?:云端|模型2)/.test(text)) {wxModel='云端模型 · 示例配置';$('demo-model').textContent='◉ 云端模型⌄';reply='已切换到云端模型 · 示例配置。';}
    else if(/(?:当前|什么|哪个).*模型|模型列表/.test(text))reply=`当前模型：${wxModel}\n\n1、本地 Ollama\n2、云端模型\n\n可说：切换到本地模型。`;
    else if(/待办|几个任务|查看任务/.test(text))reply=listText();
    else reply='这是浏览器本地演示。可试试：\n\n查看待办\n任务1标记完成\n当前模型\n切换到本地模型\n\n真实记事喵使用你配置的模型理解自由输入。';
    appendMessage(reply);wxBusy=false;wxUpdate();
    if(wxPending)signal('等待短编号确认 · 待办暂未修改');
    else if(confirmation?.[1]==='取消')signal('已取消 · 示例待办未改变');
    else if(!confirmation)signal('微信已收到回复 · 两端共用这份待办');
  }
  wxInput.addEventListener('input',wxUpdate);
  $('wx-form').addEventListener('submit',event=>{event.preventDefault();wechat(wxInput.value);});
  $('wx-list').addEventListener('click',()=>wechat('现在有几个待办？'));
  $('wx-complete').addEventListener('click',()=>{const index=tasks.findIndex(task=>!task.done);wechat(index<0?'查看待办':`任务${index+1}标记完成`);});
  $('wx-model').addEventListener('click',()=>wechat('切换到本地模型'));
  $('wx-confirm').addEventListener('click',()=>{if(wxPending)wechat('确认'+wxPending.code);});
  async function scene(name) {
    if(wxBusy || busy)return;
    if(wxPending){appendMessage('已切换演示，上一条示例确认已取消。');setPending(null);}
    document.querySelectorAll('[data-scene]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.scene===name)));
    if(name==='wechat-add')await wechat('明晚八点提醒我读书');
    else if(name==='wechat-reschedule') {const index=tasks.findIndex(task=>!task.done);await wechat(`任务${(index<0?0:index)+1}改到周五下午`);}
    else {
      const index=tasks.findIndex(task=>!task.done);
      if(index<0){signal('示例都完成啦 · 试试从微信新增一件事');return;}
      setPending(null);tasks[index].done=true;render(index);signal('在 Mac 完成一项 · 再到微信查看');
      $('demo-feedback').textContent='已在 Mac 演示面板完成「'+tasks[index].title+'」';await motionDelay(500);await wechat('现在有几个待办？');
    }
  }
  document.querySelectorAll('[data-scene]').forEach(button=>button.addEventListener('click',()=>scene(button.dataset.scene)));
  render();scene('wechat-add');
})();
