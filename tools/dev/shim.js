// мини-PostgREST для тестов: POST /rest/v1/rpc/<fn> -> select public.<fn>(...) от имени anon
const http=require('http'),{Pool}=require('pg');
const D=process.env.PGDIR||'/var/lib/postgresql/sirius',pool=new Pool({host:D,port:5433,user:'postgres',database:'postgres'});
let DOWN=false;const FILES=new Map();
http.createServer(async(req,res)=>{
  const h={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'apikey,content-type,authorization,x-upsert,cache-control','Access-Control-Allow-Methods':'GET,POST,DELETE,OPTIONS'};
  if(req.method==='OPTIONS'){res.writeHead(204,h);return res.end()}
  if(req.url==='/__down'){DOWN=true;res.writeHead(200,h);return res.end('down')}
  if(req.url==='/__up'){DOWN=false;res.writeHead(200,h);return res.end('up')}
  if(DOWN){req.destroy();return}
  const sm=req.url.match(/^\/storage\/v1\/object\/(public\/)?materials\/([^?]+)$/);
  if(sm){const name=sm[2].split('/').map(decodeURIComponent).join('/'),J=Object.assign({'Content-Type':'application/json'},h);
    if(req.method==='GET'&&sm[1]){const f=FILES.get(name);if(!f){res.writeHead(404,J);return res.end('{}')}res.writeHead(200,Object.assign({'Content-Type':f.ct},h));return res.end(f.buf)}
    if(!req.headers.apikey||req.headers.authorization){res.writeHead(401,J);return res.end('{"message":"bad auth"}')}
    const c=await pool.connect();
    try{await c.query('begin');await c.query('set local role anon');
      if(req.method==='POST'){const ch=[];for await(const d of req)ch.push(d);const buf=Buffer.concat(ch),ct=req.headers['content-type']||'';
        const b=(await c.query("select * from storage.buckets where id='materials'")).rows[0];
        if(buf.length>b.file_size_limit)throw new Error('The object exceeded the maximum allowed size');if(!b.allowed_mime_types.includes(ct))throw new Error('mime type '+ct+' is not supported');
        await c.query("insert into storage.objects(bucket_id,name,metadata) values ('materials',$1,$2)",[name,JSON.stringify({size:buf.length,mimetype:ct})]);
        await c.query('commit');FILES.set(name,{buf,ct});res.writeHead(200,J);return res.end(JSON.stringify({Key:'materials/'+name}))}
      if(req.method==='DELETE'){const r=await c.query("delete from storage.objects where bucket_id='materials' and name=$1 returning id",[name]);await c.query('commit');
        if(!r.rowCount){res.writeHead(400,J);return res.end('{"message":"Object not found"}')}FILES.delete(name);res.writeHead(200,J);return res.end('{"message":"Successfully deleted"}')}
      await c.query('rollback');res.writeHead(405,J);return res.end('{}')}
    catch(e){await c.query('rollback').catch(()=>{});res.writeHead(400,J);return res.end(JSON.stringify({statusCode:'403',error:'Unauthorized',message:e.message}))}
    finally{c.release()}}
  const m=req.url.match(/^\/rest\/v1\/rpc\/(\w+)$/);
  if(!m||req.method!=='POST'||!req.headers.apikey){res.writeHead(404,h);return res.end('{}')}
  let body='';req.on('data',d=>body+=d);await new Promise(r=>req.on('end',r));
  let args={};try{args=JSON.parse(body||'{}')}catch(_){}
  const keys=Object.keys(args),vals=keys.map(k=>{const v=args[k];if(v!==null&&typeof v==='object'&&!(Array.isArray(v)&&v.every(x=>typeof x==='string')))return JSON.stringify(v);return v});
  const c=await pool.connect();
  try{await c.query('begin');await c.query('set local role anon');await c.query("select set_config('request.headers',$1,true)",[JSON.stringify({'x-forwarded-for':req.socket.remoteAddress})]);
    const q=`select public.${m[1]}(${keys.map((k,i)=>`${k} => $${i+1}`).join(', ')}) as r`;
    const r=await c.query(q,vals);await c.query('commit');
    res.writeHead(200,Object.assign({'Content-Type':'application/json'},h));res.end(JSON.stringify(r.rows[0].r))}
  catch(e){await c.query('rollback').catch(()=>{});res.writeHead(400,Object.assign({'Content-Type':'application/json'},h));res.end(JSON.stringify({message:e.message}))}
  finally{c.release()}
}).listen(8766,()=>console.log('shim on 8766'));
