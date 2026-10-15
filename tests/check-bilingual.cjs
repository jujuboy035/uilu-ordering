const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('frontend/index.html','utf8');
const scripts=[...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const i18n=scripts.at(-2).split('const originalUI=')[0],app=scripts.at(-1);
const elements={};function element(key){return elements[key]||=( {innerHTML:'',textContent:'',style:{},classList:{toggle(){},remove(){}},remove(){}})}
const context={document:{querySelector:element,querySelectorAll:()=>[],addEventListener(){},body:{dataset:{},classList:{remove(){}},prepend(){}},createElement:()=>element('new')},localStorage:{getItem:()=>null},sessionStorage:{},window:{kuiluOriginalNav:''},location:{protocol:'https:'},supabase:{createClient:()=>({})},Date,console};
vm.createContext(context);
vm.runInContext(i18n+'\n'+app.slice(0,app.indexOf('const authStyle='))+'\n'+app.slice(app.indexOf('function loginEmail('),app.indexOf('cloud.auth.onAuthStateChange')),context);
const run=s=>vm.runInContext(s,context);
run("uiLanguage='ja';state.pickupDate='2099-01-01';state.pickupContact='客户';addresses=[{id:'cn',country:'CN',name:'客户',region:'深圳市',street:'中国取货地址',contact:'张先生',phone:'000',pending:false},{id:'jp',country:'JP',name:'配送要求',region:'東京都',street:'日本配送地址',contact:'田中',phone:'000',postal:'100-0001',pending:false}];state.cn='cn';state.jp='jp'");
assert.equal(run("roleNames.admin"),'管理者');
assert.equal(run("statusNames.pending_review"),'集荷手配待ち');
assert.equal(run("state.cargo[0].category"),'日用品');
assert(run("addressCards('CN')").includes('<h3>客户'));
assert(run("addressCards('CN')").includes('中国取货地址'));
run('step=2');
const cargo=run('body()');assert(cargo.includes('品名'));assert(!cargo.includes('英語品名'));assert(cargo.includes('色見本'));assert(cargo.includes('サンプル衣料'));assert(cargo.includes('申告単価'));
run('step=4');const delivery=run('body()');assert(delivery.includes('お届け予定'));assert(delivery.includes('2099-01-02'));assert(delivery.includes('日本時間'));
assert.equal(run("state.deliveryTime"),'12:00前');
assert.equal(run("t('12:00前')"),'12:00まで');
run('step=5');const review=run('body()');assert(review.includes('中国取货地址'));assert(review.includes('内容を確認'));
run("activeRole='admin';staffView='users';userRows=[{email:'客户@example.invalid',business_role:'customer',email_verified:true,id:'test'}];userTotal=1;renderUsers()");
assert(elements['#app'].innerHTML.includes('客户@example.invalid'));
assert(elements['#app'].innerHTML.includes('お客様'));
assert(elements['#app'].innerHTML.includes('登録済みアカウント'));
run("uiLanguage='zh-CN';renderUsers()");
assert.equal(run('roleNames.admin'),'管理员');
assert(elements['#app'].innerHTML.includes('现有用户账号'));
assert.equal(run("t('登录')"),'登录');
run("uiLanguage='ja';showAuth()");
assert.equal(context.document.title,'ログイン · 奎陆中日手提');
assert(!elements.new.innerHTML.includes('data-auth-mode'));
assert(elements.new.innerHTML.includes('メール認証は不要'));
assert.equal(run("loginEmail(' Customer01 ')"),'customer01@accounts.kuilu.invalid');
assert.equal(run("loginEmail('admin@example.com')"),'admin@example.com');
assert.throws(()=>run("loginEmail('bad account')"));
assert(!app.includes('.auth.signUp('));
assert(!app.includes('.auth.resetPasswordForEmail('));
console.log('PASS: both locales, all order steps, role/status changes, canonical payload values, and user text preservation.');

run("addresses=[];state=fresh();uiLanguage='zh-CN';step=0;view='new';render()");assert(elements['#app'].innerHTML.includes('待选择地址'));run("uiLanguage='ja';render()");assert(elements['#app'].innerHTML.includes('住所を選択'));
assert.equal(run("declaredTotal({qty:3,unitPrice:12.34})"),'37.02');
run("state.cargo[0]={...fresh().cargo[0],name:'中文',nameEn:'Test',unitPrice:'12.34',currency:'CNY',packaging:'纸箱'}");assert.equal(run('validate(2)'),'');run("state.cargo[0].unitPrice='-1'");assert(run('validate(2)').length>0);
console.log('PASS: empty-address customer render regression, declaration totals and validation');


run("state=fresh();step=2;uiLanguage='zh-CN'");assert.equal(run('state.cargo[0].currency'),'USD');assert.equal(run('state.pickupDate'),run('dateNow()'));const simple=run('body()');assert(!simple.includes('英文品名'));assert(!simple.includes('运输箱数'));assert(!simple.includes('type="file"'));assert.equal(run('state.cargo[0].packaging'),'袋子');assert(simple.includes('list="cargo-names-0"'));assert(!simple.includes('data-preset'));assert(!simple.includes('常用品名预设'));assert(simple.includes('袋子'));run('step=3');assert(!run('body()').includes('期望取货时间段'));console.log('PASS: simplified form defaults and removed required fields');

run("uiLanguage='zh-CN';activeRole='admin';usersLoading=false;usersError='';userRows=[{id:'test',username:'test',business_role:'customer'}]");assert.equal(run('roleNames.admin'),'管理员');assert(run('isManager()'));assert(!run('isSystemAdmin()'));
const sample="({dbId:'order',status:'pickup',driverId:'driver'})";
assert(run('workflowControls('+sample+')').includes('data-edit-order'));assert(run('workflowControls('+sample+')').includes('data-assign-stage'));
run("renderUsers()");assert(!elements['#app'].innerHTML.includes('data-change-role'));assert(!elements['#app'].innerHTML.includes('data-reset-account'));
run("activeRole='system_admin';renderUsers()");assert(run('isSystemAdmin()'));assert(elements['#app'].innerHTML.includes('data-change-role'));
for(const role of ['customer','china_driver','japan_driver','courier']){run('activeRole='+JSON.stringify(role));assert(!run('isManager()'));assert(!run('workflowControls('+sample+')').includes('data-edit-order'))}
run("uiLanguage='ja'");assert.equal(run('roleNames.system_admin'),'システム管理者');assert.equal(run('roleNames.china_driver'),'中国ドライバー');
console.log('PASS: six-role UI, system-only permission controls and manager-only order editing');

run("uiLanguage='zh-CN';activeRole='admin';packages=[];orders=[{dbId:'warehouse',status:'cn_warehouse',id:'TEST',cargo:[{name:'样衣'}],addressSnapshot:{cn:{name:'CN'},jp:{name:'JP'}}}];renderPackages()");assert(elements['#app'].innerHTML.includes('makePackageForm'));assert(elements['#app'].innerHTML.includes('warehouse'));
run("activeRole='courier';renderPackages()");assert(!elements['#app'].innerHTML.includes('makePackageForm'));
run("activeRole='admin'");assert(run("workflowControls({dbId:'x',deletedAt:'yes'})").includes('data-restore'));assert(!run("workflowControls({dbId:'x',status:'cn_warehouse',packageId:'pkg'})").includes('data-remove-order'));
run("activeRole='customer'");assert(!run("workflowControls({dbId:'x',status:'pickup'})").includes('data-remove-order'));
console.log('PASS: package workspace, manager-only packing/deletion, courier read-only workspace and packed-order guards');

assert.equal(run("validPickupFilterDate('2026-10-15')"),'2026-10-15');assert.equal(run("validPickupFilterDate('')"),'');assert.throws(()=>run("validPickupFilterDate('2026-02-30')"));
run("var dateCalls=[];cloud.from=()=>{const q={select(){return q},not(){return q},is(){return q},eq(k,v){dateCalls.push(['eq',k,v]);return q},order(){return q},limit(){return q}};return q};activeRole='customer';orderDateFilters.customer={date:'2026-10-15'};datedOrderQuery()");
assert.deepEqual(JSON.parse(JSON.stringify(run('dateCalls'))),[['eq','payload->>pickupDate','2026-10-15']]);
assert(!run('orderDateFilter()').includes('dateEnd'));assert(!run('orderDateFilter()').includes('结束日期'));assert(run('orderDateFilter()').includes('pickupFilterDate'));
run("activeRole='admin';staffView='packages';dateCalls=[];datedOrderQuery()");assert.equal(run('dateCalls.length'),0);
run("uiLanguage='ja'");assert(run('orderDateFilter()').includes('集荷日（中国時間）'));
console.log('PASS: single pickup-date server query, no end-date input, invalid date rejection and Japanese captions');
