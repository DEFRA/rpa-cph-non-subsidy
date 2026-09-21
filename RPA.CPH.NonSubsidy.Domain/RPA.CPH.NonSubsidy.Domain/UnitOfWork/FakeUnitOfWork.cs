using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.Repository;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.UnitOfWork
{
    public class FakeUnitOfWork : IUnitOfWork
    {
        private IRepository<Customer> customerRepository;
        private IRepository<Address> addressRepository;
        private IRepository<Land> landRepository;
        private IRepository<LandParcel> landParcelRepository;
        private IRepository<Case> caseRepository;
        private IRepository<Audit> auditRepository;

        public IRepository<Customer> CustomerRepository
        {
            get
            {
                if (this.customerRepository == null)
                {
                    this.customerRepository = new FakeRepository<Customer>();
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
                    this.addressRepository = new FakeRepository<Address>();
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
                    this.landRepository = new FakeRepository<Land>();
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
                    this.landParcelRepository = new FakeRepository<LandParcel>();
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
                    this.caseRepository = new FakeRepository<Case>();
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
                    this.auditRepository = new FakeRepository<Audit>();
                }

                return auditRepository;
            }
        }

        public void Commit()
        {

        }

        public void Dispose()
        {

        }
    }
}
