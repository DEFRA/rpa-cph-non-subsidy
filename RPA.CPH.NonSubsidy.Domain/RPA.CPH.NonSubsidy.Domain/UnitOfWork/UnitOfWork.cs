using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Repository;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;

namespace RPA.CPH.NonSubsidy.Domain.UnitOfWork
{
    public class UnitOfWork:IUnitOfWork
    { 

        private CPHContext context;
        private IRepository<Customer> customerRepository;
        private IRepository<Address> addressRepository;
        private IRepository<Land> landRepository;
        private IRepository<LandParcel> landParcelRepository;
        private IRepository<Case> caseRepository;
        private IRepository<Audit> auditRepository;
    
        public UnitOfWork()
        {
            this.context = new CPHContext();
        }

        public UnitOfWork(CPHContext context)
        {
            this.context = context;
        }

        public IRepository<Customer> CustomerRepository
        {
            get
            {
                if (this.customerRepository == null)
                {
                    this.customerRepository = new SQLRepository<Customer>(context);
                }

                return customerRepository;
            }
        }

        public IRepository<Address> AddressRepository
        {
            get
            {
                if (this.addressRepository == null)
                {
                    this.addressRepository = new SQLRepository<Address>(context);
                }

                return addressRepository;
            }
        }

        public IRepository<Land> LandRepository
        {
            get
            {
                if (this.landRepository == null)
                {
                    this.landRepository = new SQLRepository<Land>(context);
                }

                return landRepository;
            }
        }

        public IRepository<LandParcel> LandParcelRepository
        {
            get
            {
                if (this.landParcelRepository == null)
                {
                    this.landParcelRepository = new SQLRepository<LandParcel>(context);
                }

                return landParcelRepository;
            }
        }

        public IRepository<Case> CaseRepository
        {
            get
            {
                if (this.caseRepository == null)
                {
                    this.caseRepository = new SQLRepository<Case>(context);
                }

                return caseRepository;
            }
        }

        public IRepository<Audit> AuditRepository
        {
            get
            {
                if (this.auditRepository == null)
                {
                    this.auditRepository = new SQLRepository<Audit>(context);
                }

                return auditRepository;
            }
        }

        public void Commit()
        {
            context.SaveChanges();
        }

        private bool disposed = false;

        protected virtual void Dispose(bool disposing)
        {
            if (!this.disposed)
            {
                if (disposing)
                {
                    context.Dispose();
                }
            }
        }

        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }
    }
}
