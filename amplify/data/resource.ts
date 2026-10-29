import { type ClientSchema, a, defineData } from '@aws-amplify/backend';

const schema = a.schema({
  LiveMatch: a.model({
    matchId: a.string().required(),
    teamA: a.string().required(),
    teamB: a.string().required(),
    scoreA: a.integer().default(0),
    scoreB: a.integer().default(0),
    status: a.enum(['SCHEDULED', 'LIVE', 'COMPLETED']),
  }).authorization((allow) => [
    allow.guest().to(['read']),
    allow.groups(['Referees', 'Admins']).to(['update']),
  ]),
});

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    defaultAuthorizationMode: 'userPool',
  },
});
