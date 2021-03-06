# -*- coding: utf-8 -*-
"""
Created on Wed Nov  7 22:20:12 2018

@author: V0010894
"""

import pandas as pd
import yaml
import os
import sqlalchemy as sq
from datetime import datetime, timedelta
import pyodbc
import time
from glob import glob


with open('Monthly_Report_calcs.yaml') as yaml_file:
        conf = yaml.load(yaml_file)

start_date = (datetime.today() - timedelta(days=365)).strftime('%Y-%m-%d')
end_date = (datetime.today() - timedelta(days=1)).strftime('%Y-%m-%d')
dates = pd.date_range(start_date, end_date, freq='3D')
        
query = """SELECT DISTINCT SignalID, EventParam as Detector
           FROM Controller_Event_Log WHERE EventCode = 82
           AND Timestamp between '{} 08:00:00' and '{} 09:00:00';
           """

if os.name=='nt':
        
    uid = os.environ['ATSPM_USERNAME']
    pwd = os.environ['ATSPM_PASSWORD']
    dsn = 'atspm_dsn'
    
    engine = sq.create_engine('mssql+pyodbc://{}:{}@{}'.format(uid, pwd, dsn),
                              pool_size=20)

elif os.name=='posix':

    def connect():
        return pyodbc.connect(
            'Driver=FreeTDS;' + 
            'SERVER={};'.format(os.environ['ATSPM_SERVER_INSTANCE']) +
            'DATABASE={};'.format(os.environ['ATSPM_DB']) +
            'PORT=1433;' +
            'UID={};'.format(os.environ['ATSPM_USERNAME']) +
            'PWD={};'.format(os.environ['ATSPM_PASSWORD']) +
            'TDS_Version=8.0;')
    
    engine = sq.create_engine('mssql://', creator=connect)
    

with engine.connect() as conn:

    
    for date_ in dates:
        
        t0 = time.time()
        
        sd = date_.strftime('%Y-%m-%d')
        ed = sd
        
        print(sd, end=': ')
            
        df = pd.read_sql(sql=query.format(sd, ed), con=conn)
        df.to_csv('included_detectors_{}.csv'.format(sd))
        
        print('{} sec'.format(time.time() - t0))
    
    filenames = glob('included_detectors_*.csv')
    df = pd.concat([pd.read_csv(fn)[['SignalID','Detector']] for fn in filenames]).drop_duplicates()
    df.SignalID = df.SignalID.astype('int')
    
    df.to_csv('included_detectors.csv')
    
    for fn in filenames:
        os.remove(fn)
