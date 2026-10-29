import { readFile } from 'node:fs/promises';
const config=JSON.parse(await readFile(new URL('../wrangler.jsonc',import.meta.url),'utf8'));
const errors=[];
let origin;
try{origin=new URL(config.vars.PUBLIC_URL);if(origin.protocol!=='https:'||/YOUR_|example\./i.test(origin.hostname))errors.push('Set vars.PUBLIC_URL to the real HTTPS API origin.');}catch{errors.push('Set a valid PUBLIC_URL.');}
if(!config.d1_databases?.[0]?.database_id||config.d1_databases[0].database_id==='00000000-0000-0000-0000-000000000000')errors.push('Create the D1 database and set its database_id.');
if(!config.r2_buckets?.[0]?.bucket_name)errors.push('Set the private R2 bucket name.');
if(config.vars.ENVIRONMENT!=='production')errors.push('Production ENVIRONMENT must be production.');
if(errors.length){for(const error of errors)console.error(error);process.exit(1);}
console.log('Cloud bindings configured. Confirm OAuth, Stripe and TURN secrets, then apply migrations and deploy.');
