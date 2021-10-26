# Borealis Isolated Postgres Heroku Buildpack

A [Heroku buildpack](https://devcenter.heroku.com/articles/buildpacks) to establish a secure tunnel to a [Borealis Isolated Postgres](https://elements.heroku.com/addons/borealis-pg) add-on database cluster.

## Usage

Use the [Heroku CLI](https://devcenter.heroku.com/articles/heroku-cli) to add the buildpack to an existing Heroku application so the application can seamlessly connect to an add-on database over a secure tunnel:

```shell
heroku buildpacks:add --index 1 borealis/postgres-ssh
```

That's it! The buildpack will automatically detect config variables from a Borealis Isolated Postgres add-on and set up a secure tunnel the next time the application is deployed. The deployed application can then proceed to connect to the database cluster using the value from the Postgres URL config variable (e.g. `BOREALIS_PG_URL` or `DATABASE_URL`).
