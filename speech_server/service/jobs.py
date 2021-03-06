#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import unicode_literals, division, print_function #Py2

import json
import time
import uuid
import base64
import admin
import auth
import tempfile
import os
import datetime
import logging
import codecs
from functools import wraps
from types import FunctionType

LOG = logging.getLogger("SPSRV.JOBS")
ALOG = logging.getLogger("SPSRV.JOBS.ADMIN")

try:
    from sqlite3 import dbapi2 as sqlite
except ImportError:
    from pysqlite2 import dbapi2 as sqlite #for old Python versions

from httperrs import NotAuthorizedError, ConflictError, NotFoundError, BadRequestError

def authlog(okaymsg):
    """This performs authentication (inserting `username` into function
       namespace) and logs the ENTRY, FAILURE or OK return of the
       decorated method...
       http://stackoverflow.com/questions/26746441/how-can-a-decorator-pass-variables-into-a-function-without-changing-its-signatur
    """
    def decorator(f):
        logfuncname = {"funcname": f.__name__}
        @wraps(f)
        def wrapper(*args, **kw):
            self, request = args[:2]
            if not "file" in request:
                LOG.debug("ENTER: request={}".format(request), extra=logfuncname)
            else:
                LOG.debug("ENTER: without 'file' --> request={}".format(
                    dict([(k, request[k]) for k in request if k != "file"])), extra=logfuncname)
            username = None #in case exception before authenticate
            try:
                #AUTH + INSERT USERNAME INTO FUNC SCOPE
                username = self.authdb.authenticate(request["token"])
                fn_globals = {}
                fn_globals.update(globals())
                fn_globals.update({"username": username})
                call_fn = FunctionType(getattr(f, "func_code"), fn_globals) #Only Py2
                #LOG-CALL-LOG-RETURN
                LOG.info("ENTER: (username={})".format(username), extra=logfuncname)
                result = call_fn(*args, **kw)
                LOG.info("OK: (username={}) {}".format(username, okaymsg), extra=logfuncname)
                return result
            except Exception as e:
                LOG.info("FAIL: (username={}) {}".format(username, e), extra=logfuncname)
                raise
        return wrapper
    return decorator

class Admin(admin.Admin):

    def __init__(self, config_file):
        admin.Admin.__init__(self, config_file)

        self.jdb = sqlite.connect(self._config['jobsdb'], factory=JobsDB)
        self.jdb.row_factory = sqlite.Row

    @authlog("Load all jobs in db")
    def loadjobs(self, request):
        """
            Load all speech jobs in the db
        """
        ALOG.info("Loading jobs: {}".format(request))
        with self.jdb as jdb:
            jobs = jdb.all_jobs()

        ALOG.info("Returning job list")
        return {"data" : jobs}

    @authlog("Modify jobs status")
    def modifystatus(self, request):
        """
            Modify job's status
            ONLY from E (error) to X (done)
        """
        ALOG.info("Modifying job status: {}".format(request))
        pass

    @authlog("Delete a job")
    def deletejob(self, request):
        """
            Delete a job
            ONLY with status: E (error) to X (done)
        """
        ALOG.info("Deleting job: {}".format(request))
        pass

    @authlog("Load job info")
    def loadticket(self, request):
        """
            Load job info from file
        """
        ALOG.info("Loading a ticket: {}".format(request))
        with self.jdb as jdb:
            ticket = jdb.job_info(request["jobid"])

        with codecs.open(ticket[0], "r" , "utf-8") as f:
            data = json.load(f)

        ALOG.info("Returning ticket data")
        return { "data" : data }

    @authlog("Save job info")
    def saveticket(self, request):
        """
            Saving a modified ticket
        """
        ALOG.info("Saving ticket: {}".format(request))
        with self.jdb as jdb:
            ticket = jdb.job_info(request["jobid"])

        with codecs.open(ticket[0], "w" , "utf-8") as f:
            data = json.dump(request["ticket"], f)

        ALOG.info("Ticket data saved")
        return "New job information saved"

    @authlog("Stop scheduler")
    def schedstop(self, request):
        """
            Stop the scheduler from running any new jobs
        """
        ALOG.info("Stopping scheduler: {}".format(request))
        with self.jdb as jdb:
            jdb.adminlock()

        ALOG.info("Scheduler stopped")
        return "Scheduler stopped"

    @authlog("Start scheduler")
    def schedstart(self, request):
        """
            Start the scheduler
        """
        ALOG.info("Starting scheduler: {}".format(request))
        with self.jdb as jdb:
            jdb.adminunlock()

        ALOG.info("Scheduler started")
        return "Scheduler started"

    @authlog("Scheduler status")
    def schedstatus(self, request):
        """
            Return scheduler status
        """
        ALOG.info("Checking scheduler status: {}".format(request))
        with self.jdb as jdb:
            status = jdb.adminlockstatus()

        ALOG.info("Returning scheduler status: {}".format(status[0]))
        return { "status" : status[0] }

    @authlog("Clear job error")
    def clearerror(self, request):
        """
            Clear job that is in error
        """
        ALOG.info("Clearing job error: {}".format(request))
        with self.jdb as jdb:
            jdb.clearerror(request["jobid"])

        ALOG.info("Error cleared for jobid: {}".format(jobid))
        return "Error cleared"

    @authlog("Resubmit job if in error and fixed")
    def resubmit(self, request):
        """
            Resubmit a job after fixing
        """
        ALOG.info("Resubmitting job: {}".format(request))
        with self.jdb as jdb:
            status = jdb.jobstatus(request["jobid"])
            if status[0] != "E":
                ALOG.error("Job ({}) in not in an error state ({})".format(request["jobid"], status[0]))
                raise BadRequestError("Job ({}) in not in an error state ({})".format(request["jobid"], status[0]))

            jdb.resubmit(request["jobid"])
        ALOG.info("Job resubmitted jobid: {}".format(request["jobid"]))
        return "Resubmitted job"

class Jobs(auth.UserAuth):

    def __init__(self, config_file):
        with open(config_file) as infh:
            self._config = json.loads(infh.read())

        auth.UserAuth.__init__(self, config_file)

        #DB connection setup:
        self.jdb = sqlite.connect(self._config['jobsdb'], factory=JobsDB)
        self.jdb.row_factory = sqlite.Row

        self.sdb = sqlite.connect(self._config['servicesdb'], factory=ServicesDB)
        self.sdb.row_factory = sqlite.Row

    @authlog("Adding jobs")
    def add_job(self, request):
        """
            Add job to the queue
        """
        LOG.info("Adding job to queue: {}".format(request))
        # Check request is valid
        with self.sdb as sdb:
            services = sdb.get_services()

            job = {}
            for serv in services:
                if serv["name"] == request["service"]:
                    job["service"] = request["service"]
                    job["command"] = serv["command"]

            if not job:
                LOG.error("Requested service %s: not found!" % request["service"])
                raise NotFoundError("Requested service %s: not found!" % request["service"])

            # Check that all parameters have been set
            require = sdb.get_requirements()
            for item in require:
                if item["name"] == request["service"]:
                    job["audio"] = item["audio"]
                    job["text" ] = item["text"]

            if job["audio"] == 'Y' and "getaudio" not in request:
                LOG.error("Requested service %s: requires 'getaudio' in paramaters" % request["service"])
                raise NotFoundError("Requested service %s: requires 'getaudio' in paramaters" % request["service"])

            if job["text"] == 'Y' and "gettext" not in request:
                LOG.error("Requested service %s: requires 'gettext' in paramaters" % request["service"])
                raise NotFoundError("Requested service %s: requires 'gettext' in paramaters" % request["service"])

            # Check subsystem
            subsystems = sdb.get_subsystems(request["service"])
            subsys = [x["subsystem"] for x in subsystems]
            if request["subsystem"] not in subsys:
                LOG.error("Requested service subsystem %s: not found!" % request["subsystem"])
                raise NotFoundError("Requested service subsystem %s: not found!" % request["subsystem"])

        # Add job to job db
        with self.jdb as jdb:
            # Generate new job id
            jobid = "j{}".format(str(uuid.uuid4().hex))

            # Write the job information to job file
            new_date = datetime.datetime.now()
            ticket = os.path.join(self._config["storage"], username, str(new_date.year), str(new_date.month), str(new_date.day), jobid)
            if not os.path.exists(ticket): os.makedirs(ticket)
            LOG.info("Writing ticket to: ".format(ticket))

            ticket = os.path.join(ticket, jobid)
            job.update(request)
            with codecs.open(ticket, "w", "utf-8") as f:
                json.dump(job, f)
            LOG.info("Wrote ticket: {}".format(ticket))

            # Add job entry to table
            jdb.add_new_job(jobid, username, ticket, time.time())
            LOG.info("Adding new job: {}".format(jobid))

            return {'jobid' : jobid}

    @authlog("Marking job for deletion")
    def delete_job(self, request):
        """
            Delete job from the queue if the job is not running
        """
        LOG.info("Deleting job: {}".format(request))
        with self.jdb as jdb:
            jdb.lock()
            jobid = jdb.check_job(request["jobid"])

            # See if job exists
            if not jobid:
                LOG.error("job does not exist: {}".format(jobid))
                raise NotFoundError("job does not exist")

            # Mark job with "X"
            jdb.delete_job(request["jobid"])

        LOG.info("Job marked for deletion: {}".format(jobid))
        return "Job marked for deletion"

    @authlog("Query specific job")
    def query_job(self, request):
        """
            Query job and return information
        """
        LOG.info("Querying job: {}".format(request))
        with self.jdb as jdb:
            job_info = {}
            job_info["ticket"] = jdb.job_info(request["jobid"])

            # See if job exists
            if not job_info:
                LOG.error("job does not exist")
                raise NotFoundError("job does not exist")

            with codecs.open(job_info["ticket"][2], "r", "utf-8") as f:
                info = json.load(f)
            job_info.update(info)

            LOG.info("Returning job information")
            return job_info

    @authlog("List all user's jobs")
    def user_jobs(self, request):
        """
            Query all jobs belonging to the user and return job ids
        """
        LOG.info("Finding all jobs belonging to user: {}".format(request))
        with self.jdb as jdb:
            jobs = jdb.users_jobs(username)
            if not jobs:
                LOG.error("No jobs found")
                raise NotFoundError("No jobs found")
            LOG.debug("{}".format(jobs))
            jobs_ids = [x["jobid"] for x in jobs]
            LOG.info("Returning jobids")
            return {"jobids": jobs_ids}

    @authlog("List all services and subsystems")
    def discover(self, request):
        """
            Return all services and subsystems to user
        """
        LOG.info("Listing services and subsystems: {}".format(request))
        with self.sdb as sdb:
            # List services
            services = sdb.get_services()
            service_names = []
            for serv in services:
                service_names.append(serv["name"])

            # List service requirements
            require = sdb.get_requirements()

            # List subsystems
            subsystems = {}
            for serv in service_names:
                subs = sdb.get_subsystems(serv)
                subsystems[serv] = subs

        LOG.info("Returning services, requirements and subsystems")
        return {'services' : service_names, 'requirements' : require, 'subsystems' : subsystems}


class JobsDB(sqlite.Connection):
    def lock(self):
        self.execute("BEGIN IMMEDIATE")

    def add_new_job(self, jobid, username, ticket, time):
        self.execute("INSERT INTO jobs (jobid, username, ticket, status, sgeid, creation, errstatus) VALUES(?,?,?,?,?,?,?)",
            (jobid, username, ticket, "P", None, time, None))

    def check_job(self, jobid):
        jobid = self.execute("SELECT jobid FROM jobs WHERE jobid=?", (jobid,)).fetchone()
        if jobid is None:
            return []
        return list(jobid)

    def delete_job(self, jobid):
        self.execute("UPDATE jobs SET status='X' WHERE jobid=?", (jobid,))

    def job_info(self, jobid):
        row = self.execute("SELECT ticket FROM jobs WHERE jobid=?", (jobid,)).fetchone()
        if row is None:
            return ''
        return list(row)

    def users_jobs(self, username):
        rows = self.execute("SELECT jobid FROM jobs WHERE username=?", (username,)).fetchall()
        if rows is None:
            return []
        return map(dict, rows)

    def all_jobs(self):
        rows = self.execute("SELECT * FROM jobs").fetchall()
        if rows is None:
            return []
        return map(dict, rows)

    def adminlock(self):
        self.execute("UPDATE jobCtrl SET value='Y' WHERE key=?", ('lock',))

    def adminunlock(self):
        self.execute("UPDATE jobCtrl SET value='N' WHERE key=?", ('lock',))

    def adminlockstatus(self):
        row = self.execute("SELECT value FROM jobCtrl WHERE key=?", ('lock',)).fetchone()
        if row is None:
            return ['ERROR: key not found']
        return list(row)

    def clearerror(self, jobid):
        self.execute("UPDATE jobs SET errstatus=? WHERE jobid=?", (None, jobid))

    def jobstatus(self, jobid):
        status = self.execute("SELECT status FROM jobs WHERE jobid=?", (jobid,)).fetchone()
        if status is None:
            return []
        return list(status)

    def resubmit(self, jobid):
        self.execute("UPDATE jobs SET status=? WHERE jobid=?", ('P', jobid))


class ServicesDB(sqlite.Connection):
    def lock(self):
        self.execute("BEGIN IMMEDIATE")

    def get_services(self):
        rows = self.execute("SELECT * FROM services").fetchall()
        if rows is None:
            return []
        return map(dict, rows)

    def get_requirements(self):
        rows = self.execute("SELECT * FROM require").fetchall()
        if rows is None:
            return []
        return map(dict, rows)

    def get_subsystems(self, service):
        rows = self.execute("SELECT * FROM {}".format(service)).fetchall()
        if rows is None:
            return []
        return map(dict, rows)

