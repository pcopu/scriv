import type { Env } from './types';
import { authenticate } from './access';
import { authRoutes } from './auth';
import { billingReturn, billingRoutes, reconcileBilling, webhook } from './billing';
import { APIError, assert, failure, id, json, rateLimit } from './http';
import { iceServers, mediaRoutes, projectDevices, reconcileMedia } from './media';
import { joinPage, teamRoutes } from './teams';
export { ProjectRoom } from './project-room';
export { BillingCoordinator } from './billing';

export default {
  async fetch(request:Request,env:Env,ctx:ExecutionContext):Promise<Response>{
    try{
      const url=new URL(request.url);
      if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{Allow:'GET,POST,PUT,PATCH,DELETE,OPTIONS'}});
      if(url.pathname==='/health'&&request.method==='GET')return json({ok:true,service:'scriv',version:'0.1.0'});
      if(url.pathname==='/billing/webhook'&&request.method==='POST')return await webhook(request,env);
      if(url.pathname==='/billing/return'&&request.method==='GET')return billingReturn(request);
      const join=/^\/join\/([A-Za-z0-9_-]{32,128})$/.exec(url.pathname);if(join&&request.method==='GET')return joinPage(join[1]!);
      if(url.pathname.startsWith('/auth/')){const result=await authRoutes(request,env);if(result)return result;}
      if(!url.pathname.startsWith('/v1/'))throw new APIError(404,'not_found','Scriv API route not found.');
      const identity=await authenticate(request,env);
      if(url.pathname==='/v1/config'&&request.method==='GET')return json({teamPrice:{currency:'usd',amount:999,interval:'month'},maxAssetBytes:Math.min(26214400,Number(env.ASSET_MAX_BYTES)||26214400),teamStorageBytes:Number(env.TEAM_STORAGE_BYTES)||10737418240,seatLimit:null,relayAvailable:!!(env.TURN_KEY_ID&&env.TURN_API_TOKEN)});
      await rateLimit(env,`request:${identity.sessionId}`,1200,60000);
      const billing=await billingRoutes(request,env,identity);if(billing)return billing;
      const media=await mediaRoutes(request,env,identity);if(media)return media;
      const team=await teamRoutes(request,env,identity);if(team)return team;
      const project=/^\/v1\/projects\/([^/]+)\/(.+)$/.exec(url.pathname);
      if(project){
        const projectId=id(project[1]);
        if(project[2]==='ice-servers'&&request.method==='GET')return await iceServers(request,env,identity,projectId);
        if(project[2]==='devices'&&request.method==='GET')return await projectDevices(env,identity,projectId);
        const allowed=/^(snapshot|events|history|commands|import|restore|leases|threads(?:\/[^/]+(?:\/messages)?)?|signals|socket)$/.test(project[2]!);assert(allowed,404,'not_found','Project API route not found.');
        return await env.PROJECTS.get(env.PROJECTS.idFromName(projectId)).fetch(request);
      }
      throw new APIError(404,'not_found','Scriv API route not found.');
    }catch(error){return failure(error);}
  },
  async scheduled(_event:ScheduledController,env:Env,ctx:ExecutionContext):Promise<void>{
    ctx.waitUntil((async()=>{
      await env.DB.batch([
        env.DB.prepare('DELETE FROM oauth_states WHERE expires_at<?').bind(Date.now()),
        env.DB.prepare('DELETE FROM auth_codes WHERE expires_at<?').bind(Date.now()),
        env.DB.prepare('DELETE FROM sessions WHERE expires_at<?').bind(Date.now()-30*86400000),
        env.DB.prepare('DELETE FROM security_limits WHERE expires_at<?').bind(Date.now())
      ]);
      await Promise.all([reconcileMedia(env),reconcileBilling(env)]);
    })());
  }
} satisfies ExportedHandler<Env>;
